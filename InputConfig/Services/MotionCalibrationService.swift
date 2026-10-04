import AppKit
import Foundation
import GameController
import IOKit
import IOKit.hid
import QuartzCore

/// One controller's motion calibration: the gyro and accel readings observed
/// while the controller was held perfectly still. The mapping engine
/// subtracts these from every incoming sample so the controller's resting
/// drift never produces fake motion. Stored per controller identity so a
/// DualSense Edge and a DualShock 4 each keep their own zero.
struct MotionCalibration: Codable, Hashable {
    /// Stable identity string for the controller (see `MotionCalibrationService.identityKey`).
    var controllerKey: String
    /// Resting gyro reading (rad/s) when the controller is flat and still.
    var gyroDriftX: Float
    var gyroDriftY: Float
    var gyroDriftZ: Float
    /// Resting user-acceleration reading (g, gravity removed).
    var accelDriftX: Float
    var accelDriftY: Float
    var accelDriftZ: Float
    var savedAt: Date
}

/// Stores per-controller motion drift calibrations on disk, applies them to
/// raw gyro/accel samples, and tracks whether the user has calibrated each
/// controller identity. Lives alongside `TouchpadService` as a separate
/// concern so motion calibration data persists independently.
final class MotionCalibrationService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = MotionCalibrationService()

    private let lock = NSLock()
    private var byKey: [String: MotionCalibration] = [:]

    private init() {
        load()
        clearedKeys = Set(UserDefaults.standard.stringArray(forKey: Self.clearedKeysKey) ?? [])
    }

    // MARK: - Persistence

    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("motionCalibration.json")
    }()

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: MotionCalibration].self, from: data) else {
            return
        }
        byKey = decoded
    }

    /// Every stored calibration, for a backup.
    func exportData() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return byKey.isEmpty ? nil : try? JSONEncoder().encode(byKey)
    }

    /// Add calibrations from a backup for controllers this Mac has none
    /// for. Existing ones stay: they were measured on this Mac. Returns
    /// how many were added.
    @discardableResult
    func mergeImported(_ data: Data) -> Int {
        guard let decoded = try? JSONDecoder().decode([String: MotionCalibration].self, from: data) else { return 0 }
        lock.lock()
        var added = 0
        for (key, value) in decoded where byKey[key] == nil {
            byKey[key] = value
            added += 1
            if clearedKeys.remove(key) != nil { persistClearedKeys() }
            // A per-pad key from another Mac never matches here (its salt
            // stays there); the model key lets the first pad of that model
            // adopt it.
            if let model = Self.legacyKey(of: key), byKey[model] == nil, decoded[model] == nil {
                byKey[model] = value
            }
        }
        lock.unlock()
        if added > 0 { saveToDisk() }
        return added
    }

    /// Writes happen off the caller's thread, in order. The table is
    /// copied under the lock first; encoding it unlocked raced the poll
    /// loop's drift updates.
    private let writeQueue = DispatchQueue(label: "com.inputconfig.motionCalibration.write", qos: .utility)

    private func saveToDisk() {
        lock.lock()
        let snapshot = byKey
        lock.unlock()
        writeQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: - Identity

    /// The model part of a controller's identity: vendor name and
    /// category. This alone is what 1.5 and earlier stored calibrations
    /// under, so two identical pads shared one zero.
    static func baseKey(for controller: GCController) -> String {
        let vendor = controller.vendorName ?? "Controller"
        let category = controller.productCategory
        return "\(vendor)|\(category)"
    }

    /// Per-controller identity key: the model, plus the pad's serial (or
    /// its unique device ID) when the system reports one, so two identical
    /// DualSenses each keep their own zero and drift learning on one no
    /// longer drags the other's. A pad with no serial keeps the model key.
    /// A calibration stored under the model key by an older version is
    /// still found (see `resolvedKey`).
    static func identityKey(for controller: GCController) -> String {
        let base = baseKey(for: controller)
        if let identity = SonyPadIdentity.of(controller: controller) {
            // Hashed: these keys go to disk and into backups, and a raw
            // serial is often the pad's Bluetooth address.
            // The unique ID first: it comes from GameController and is there
            // on the first read, while the serial arrives only once the HID
            // lineage fills in, so keying on the serial first stored a
            // calibration under one key and looked it up under another.
            if let unique = identity.uniqueID, !unique.isEmpty { return base + "#" + DeviceSerial.hashed(unique) }
            if let serial = identity.serial, !serial.isEmpty { return base + "#" + DeviceSerial.hashed(serial) }
        }
        return base
    }

    /// The model key inside a per-pad key, or nil for a model key.
    private static func legacyKey(of key: String) -> String? {
        guard let hash = key.firstIndex(of: "#") else { return nil }
        return String(key[..<hash])
    }

    /// First read of a per-pad key with nothing stored under it adopts the
    /// model key's calibration, copied, so a pad calibrated before 1.6
    /// keeps its zero and then drifts on its own. Call locked.
    private func lookupLocked(_ key: String) -> MotionCalibration? {
        if let hit = byKey[key] { return hit }
        // A pad whose zero was cleared does not take its twin's from the
        // model key; that undid Clear.
        guard !clearedKeys.contains(key),
              let legacy = Self.legacyKey(of: key), var copy = byKey[legacy] else { return nil }
        copy.controllerKey = key
        byKey[key] = copy
        return copy
    }

    // MARK: - Public API

    func calibration(forKey key: String) -> MotionCalibration? {
        lock.lock(); defer { lock.unlock() }
        return lookupLocked(key)
    }

    func isCalibrated(forKey key: String) -> Bool {
        calibration(forKey: key) != nil
    }

    /// Pads whose zero was cleared. Drift learning does not seed a new zero
    /// for them, which undid Clear about a second later, until the user
    /// zeros or calibrates again. Kept across launches, or the next launch
    /// seeded a zero and Clear was undone.
    private var clearedKeys: Set<String> = []
    private static let clearedKeysKey = "InputConfig.motion.clearedKeys"
    /// Call locked.
    private func persistClearedKeys() {
        UserDefaults.standard.set(clearedKeys.sorted(), forKey: Self.clearedKeysKey)
    }

    /// The model key of `key` while no other pad of that model has its own
    /// key: a pad's calibration and re-zero button are mirrored there, so
    /// they are still found if the pad's identity reads differently on the
    /// next connection. Call locked.
    private func soleModelKeyLocked(for key: String) -> String? {
        // Only while no other pad of that model has its own key: twins shared
        // a zero and a re-zero button through the model key.
        guard let model = Self.legacyKey(of: key) else { return nil }
        let others = byKey.keys.contains { $0 != key && $0.hasPrefix(model + "#") }
            || ((UserDefaults.standard.dictionary(forKey: Self.rezeroButtonsKey) as? [String: Int]) ?? [:])
                .keys.contains { $0 != key && $0.hasPrefix(model + "#") }
        return others ? nil : model
    }

    /// True when the user cleared this pad's zero and has not zeroed it
    /// again; drift learning leaves it alone until then.
    func wasCleared(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return clearedKeys.contains(key)
    }

    func save(_ calibration: MotionCalibration) {
        lock.lock()
        if clearedKeys.remove(calibration.controllerKey) != nil { persistClearedKeys() }
        byKey[calibration.controllerKey] = calibration
        if let model = soleModelKeyLocked(for: calibration.controllerKey) { byKey[model] = calibration }
        lock.unlock()
        saveToDisk()
        #if DEBUG
        print("[MotionCalibration] saved drift for \(calibration.controllerKey): " +
              "gyro \(calibration.gyroDriftX),\(calibration.gyroDriftY),\(calibration.gyroDriftZ) " +
              "accel \(calibration.accelDriftX),\(calibration.accelDriftY),\(calibration.accelDriftZ)")
        #endif
    }

    func clear(forKey key: String) {
        lock.lock()
        byKey.removeValue(forKey: key)
        clearedKeys.insert(key)
        persistClearedKeys()
        // The model key would be adopted again on the next read. Any other
        // identical pad that is connected has already taken its own copy.
        if let legacy = Self.legacyKey(of: key) { byKey.removeValue(forKey: legacy) }
        lock.unlock()
        saveToDisk()
    }

    /// One-shot calibration: take the controller's current motion
    /// reading as the new "rest" baseline. Driven from a toolbar
    /// button so users can re-zero on a flat surface with one click
    /// instead of opening the per-binding edit menu and running the
    /// multi-second still-hold capture.
    func quickZero(forKey key: String,
                   gyroX: Float, gyroY: Float, gyroZ: Float,
                   accelX: Float, accelY: Float, accelZ: Float) {
        let cal = MotionCalibration(
            controllerKey: key,
            gyroDriftX: gyroX, gyroDriftY: gyroY, gyroDriftZ: gyroZ,
            accelDriftX: accelX, accelDriftY: accelY, accelDriftZ: accelZ,
            savedAt: Date()
        )
        save(cal)
    }

    // MARK: - Re-zero button

    /// Button index (the same numbering the editor's Scan uses) that
    /// re-zeros a controller's motion whenever it is pressed, preset or no
    /// preset. Chosen in the Motion Calibration sheet, keyed by the same
    /// controller identity as the calibration itself, so it follows the
    /// controller rather than a preset.
    private static let rezeroButtonsKey = "InputConfig.motion.rezeroButtons"

    func rezeroButton(forKey key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let table = UserDefaults.standard.dictionary(forKey: Self.rezeroButtonsKey) as? [String: Int]
        // -1 marks "none" chosen for this pad, so the model key's button
        // is not adopted again.
        if let own = table?[key] { return own >= 0 ? own : nil }
        return Self.legacyKey(of: key).flatMap { table?[$0] }
    }

    func setRezeroButton(_ index: Int?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        var table = (UserDefaults.standard.dictionary(forKey: Self.rezeroButtonsKey) as? [String: Int]) ?? [:]
        table[key] = index ?? (Self.legacyKey(of: key) != nil ? -1 : nil)
        // Mirrored to the model key while this is the only pad of its
        // model, like the calibration.
        if let index, let model = soleModelKeyLocked(for: key) { table[model] = index }
        UserDefaults.standard.set(table, forKey: Self.rezeroButtonsKey)
    }

    /// Move the stored gyro drift a little toward what a resting controller
    /// is reading right now. Called from the poll loop only after the
    /// controller has been still for a while, so the zero follows the
    /// sensor's slow thermal wander without anyone pressing anything.
    /// Written to disk at most every 30 seconds; the zero in memory is
    /// what the engine reads, so the file only needs to catch up.
    private var lastDriftSave: CFTimeInterval = 0
    func nudgeGyroDrift(dx: Float, dy: Float, dz: Float, forKey key: String) {
        lock.lock()
        // A cleared pad is left alone only while it has no zero of its own;
        // one zeroed again or restored from a backup learns drift again.
        if clearedKeys.contains(key) {
            if byKey[key] == nil { lock.unlock(); return }
            clearedKeys.remove(key)
            persistClearedKeys()
        }
        var cal = lookupLocked(key) ?? MotionCalibration(controllerKey: key,
                                                  gyroDriftX: 0, gyroDriftY: 0, gyroDriftZ: 0,
                                                  accelDriftX: 0, accelDriftY: 0, accelDriftZ: 0,
                                                  savedAt: Date())
        cal.gyroDriftX += dx; cal.gyroDriftY += dy; cal.gyroDriftZ += dz
        byKey[key] = cal
        let now = CACurrentMediaTime()
        let due = now - lastDriftSave > 30
        if due { lastDriftSave = now }
        lock.unlock()
        if due { saveToDisk() }
    }

    /// Subtract the stored drift from a raw gyro value. Returns the value
    /// unchanged if the controller hasn't been calibrated yet: better to
    /// have uncorrected motion than no motion.
    func correctedGyro(x: Float, y: Float, z: Float, forKey key: String) -> (Float, Float, Float) {
        guard let cal = calibration(forKey: key) else { return (x, y, z) }
        return (x - cal.gyroDriftX, y - cal.gyroDriftY, z - cal.gyroDriftZ)
    }

    /// Subtract the stored drift from a raw accel value.
    func correctedAccel(x: Float, y: Float, z: Float, forKey key: String) -> (Float, Float, Float) {
        guard let cal = calibration(forKey: key) else { return (x, y, z) }
        return (x - cal.accelDriftX, y - cal.accelDriftY, z - cal.accelDriftZ)
    }
}


// MARK: - Chassis tap input

/// Main-thread mirror of tap gestures for views: rows light up on a knock
/// the way they do on a button, with or without a preset running.
@MainActor
final class ChassisTapActivity: ObservableObject {
    static let shared = ChassisTapActivity()
    /// Serialized input keys ("cht 2") that just fired, held for a moment.
    @Published private(set) var activeKeys: Set<String> = []
    private static let hold = 0.45

    fileprivate func fire(count: Int) {
        #if DEBUG
        // The marketing capture waits for a real knock: each counted gesture
        // leaves its count in the sandbox's tmp folder for the script to see.
        try? "\(count)".write(toFile: NSTemporaryDirectory() + "inputconfig-tap", atomically: true, encoding: .utf8)
        #endif
        let key = "cht \(count)"
        activeKeys.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold) { [weak self] in
            self?.activeKeys.remove(key)
        }
    }
}

/// Reads the MacBook's own accelerometer and turns a physical tap on the case
/// into a bindable input, so someone who cannot reach a button can tap the
/// laptop instead.
///
/// The sensor is an HID device published by the SPU (sensor processing unit)
/// on Apple silicon MacBooks. Three things about it are not obvious:
///
///  1. Opening the device succeeds but delivers ZERO reports until the driver
///     is woken. The wake is a `ReportInterval` write on the accelerometer's
///     own `AppleSPUHIDDriver` registry service (one of several, one per SPU
///     sensor). Writing it on the opened client device does nothing.
///  2. Under the App Store sandbox, reading needs `com.apple.security.device.usb`,
///     and since macOS 27 the wake also needs the temporary exception
///     `com.apple.security.temporary-exception.iokit-user-client-class` naming
///     `AppleSPUHIDDriver`; without it the write is refused (not permitted).
///  3. The wake does not stick. When the chassis is still, macOS parks the
///     IMU: the HID device stays open and simply stops delivering, or drops
///     to a ~100 Hz idle rate that misses a 10 ms knock outright. A single
///     wake at open therefore works on a machine that is handled right after
///     activation and fails on one that sat still first, which is how an
///     M1 Pro that publishes the sensor once produced no taps at all. The run
///     loop measures silence and rate and re-runs the full wake whenever the
///     stream looks parked, and again after the Mac wakes from sleep.
///
/// Verified on an M4 Max: ~800 Hz, 4027 reports in 5 s, sandboxed.
/// The service names are not in any public SDK header, so every step fails
/// softly and the feature simply does not appear when the sensor is absent.
final class ChassisTapService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = ChassisTapService()

    // MARK: - Who wants the sensor

    /// The sensor runs while anyone has a reason for it: the engine because
    /// the active preset binds a tap, the editor so rows light up and Scan
    /// can hear a knock, the calibrator, the scanner. Reasons are a set, so
    /// releasing something that never retained is harmless, and the stream
    /// stops the moment the last reason goes away.
    private var reasons: Set<String> = []
    func retain(_ reason: String) {
        lock.lock()
        reasons.insert(reason)
        let running = isRunning
        lock.unlock()
        // Whenever it is not running, not only when the set was empty: after
        // a failed open the reasons stay but the thread is gone.
        if !running { start() }
    }
    func release(_ reason: String) {
        lock.lock()
        reasons.remove(reason)
        let empty = reasons.isEmpty
        lock.unlock()
        if empty { stop() }
    }

    // MARK: - Scanning

    private var scanCallback: ((Int) -> Void)?
    /// The scan overlay listens for one committed gesture. Retains the
    /// sensor for the duration so a knock is heard even with no preset on.
    func startScanning(_ completion: @escaping (Int) -> Void) {
        lock.lock(); scanCallback = completion; lock.unlock()
        retain("scan")
    }
    func stopScanning() {
        lock.lock(); scanCallback = nil; lock.unlock()
        release("scan")
    }

    // HID identification
    private static let vendorUsagePage: UInt32 = 0xFF00
    private static let accelerometerUsage: UInt32 = 3
    private static let reportLength = 22
    private static let dataOffset = 6          // 3 x Int32 little endian follow
    private static let imuScale = 65536.0      // raw units per g
    private static let wakeIntervalUs: Int32 = 8000
    private static let runIntervalUs: Int32 = 1250   // ~800 Hz

    // Detection tuning, in g
    /// Default floor so gentle handling is ignored. The live value is
    /// `minPeak`, which the tap calibrator lets the user move.
    static let defaultMinPeak = 0.055
    static let minPeakKey = "InputConfig.tap.minPeak"
    /// Threshold floor in g. Read under the lock; written by the calibrator.
    private var minPeak: Double = ChassisTapService.storedMinPeak()

    /// The saved threshold, kept in the slider's range.
    private static func storedMinPeak() -> Double {
        let v = UserDefaults.standard.double(forKey: minPeakKey)
        return v > 0 ? min(1.0, max(0.01, v)) : defaultMinPeak
    }

    /// Takes up a threshold written to defaults by a backup restore now,
    /// not at the next launch.
    func reloadThresholdFromDefaults() {
        let v = Self.storedMinPeak()
        lock.lock(); minPeak = v; lock.unlock()
    }
    /// Stream health: a parked IMU shows up as silence or a low rate.
    private static let parkedSilence = 0.25
    private static let parkedRateHz = 450.0
    /// How often a wake is retried while macOS is refusing it.
    private static let deniedRetryInterval = 5.0
    /// Accepted wakes and still silent this long: reopen the device.
    private static let reopenAfterSilence = 10.0
    /// How far above the noise floor a strike must sit when the floor is
    /// genuinely high (a train, a washing machine). On a still desk the floor
    /// is ~0.003 g, so this only matters when the user's own threshold is
    /// below it; the threshold line the user sets is otherwise THE line.
    private static let snrMultiplier = 4.0
    /// A crossing this soon after a counted strike is its ring-down, not a
    /// new strike. Measured ring-down lasts 40-85 ms; this covers a hard slam.
    private static let ringWindow = 0.30
    /// The noise floor only learns from samples this long after the last
    /// crossing, so a strike's decaying tail never lifts it.
    private static let floorQuietAfterCrossing = 0.30
    private static let ringNoteInterval = 0.040
    /// Floor on tap-to-tap spacing. Measured real double taps land ~280 ms
    /// apart, so this has plenty of room while still rejecting a bounce.
    private static let refractory = 0.150
    /// The real fix for double-counting. A fingertip strike does not produce
    /// one spike: it rings for 40-85 ms, crossing the threshold in a dozen
    /// decaying lobes, and any fixed refractory shorter than the ring-down
    /// counts the tail as a second tap. Instead a new strike requires the
    /// signal to have been genuinely BELOW the threshold for this long first,
    /// which adapts to however long this particular chassis rings.
    private static let quietBeforeStrike = 0.080
    /// Gap that still belongs to the same gesture. Taps further apart than this
    /// start a new count, so "tap ... pause ... tap" is two singles, never a
    /// double. Sits just under the macOS double-click default so it feels
    /// familiar without being twitchy.
    private static let interTapWindow = 0.450
    /// Reaching this many taps commits immediately instead of waiting out the
    /// window. Five is the most a binding can ask for, so a fifth tap fires
    /// the moment it lands and a sixth starts a fresh gesture.
    private static let maxTaps = 5

    private let lock = NSLock()
    /// Signaled when the sensor thread has fully exited; starts as signaled
    /// so the first start() does not wait.
    private let threadDone: DispatchSemaphore = { let s = DispatchSemaphore(value: 0); s.signal(); return s }()
    private var device: IOHIDDevice?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private(set) var isRunning = false
    /// Bumped by every start and stop. A sensor thread runs only while the
    /// generation it was started with is current, so a release and retain in
    /// the same main-thread turn cannot leave an old thread streaming beside
    /// a new one (every sample was then processed twice).
    private var generation = 0
    /// Sensor-thread only: how the stream is doing, for honest log lines.
    private enum StreamState { case starting, streaming, parked }
    private var streamState = StreamState.starting
    private var wakeAttempts = 0
    /// Reopens in a row with no stream between them.
    private var consecutiveReopens = 0
    /// Whether any report arrived since start(), across reopens. Under lock.
    private var _reportedThisSession = false
    /// Published once the sensor is there but has sent nothing through
    /// three reopens (an M1 or M2 MacBook that never streams). Under lock.
    private var _notResponding = false
    /// Whether the refusal was logged this session. Under lock.
    private var deniedLogged = false
    /// The driver's ReportInterval before the first wake. Under lock.
    private var originalReportInterval: Int32?
    private var lastOpenError: String?

    // Stream health, kept under the lock.
    private var lastReportAt: TimeInterval = 0
    private var rateBucketStart: TimeInterval = 0
    private var rateBucketCount = 0
    private var measuredHz = 0.0
    private var lastLightWake: TimeInterval = 0
    private var rewakes = 0
    /// Set by the first report after an open, so "streaming" is only logged
    /// once data has really arrived.
    private var sawReport = false
    /// Set by the removal callback when IOKit tears the device down.
    private var deviceRemoved = false
    #if DEBUG
    /// Until this time the snapshot reports a healthy stream (synthetic tap).
    var debugHealthyUntil: Double = 0
    #endif
    /// Why the last open failed, for the calibrator and the tapstats hook.
    /// Why the sensor could not be opened, or nil. Written on the sensor
    /// thread and read on main, so it goes through the lock like the rest
    /// of the shared state: a torn String read is a crash.
    private(set) var lastError: String? {
        get { lock.lock(); defer { lock.unlock() }; return _lastError }
        set { lock.lock(); _lastError = newValue; lock.unlock() }
    }
    private var _lastError: String?
    /// True while macOS refuses to let the sensor be switched on. See wakeDriver().
    var wakeDenied: Bool { lock.lock(); defer { lock.unlock() }; return _wakeDenied }
    private var _wakeDenied = false
    /// Who is keeping the sensor up right now, for the tapstats hook.
    var activeReasons: [String] { lock.lock(); defer { lock.unlock() }; return reasons.sorted() }
    private var sleepObservers: [NSObjectProtocol] = []
    /// 1 / |gravity|, so thresholds stay in real g even if a chip reports the
    /// IMU in different units than the 65536-per-g seen on the M4 Max. Held at
    /// 1 until the gravity estimate is plausible, so garbage never scales up.
    private var unitScale = 1.0

    // Recent residual magnitudes for the calibrator's live plot.
    private static let ringCapacity = 4096
    private var ringMag = [Double](repeating: 0, count: 4096)
    private var ringTime = [Double](repeating: 0, count: 4096)
    private var ringHead = 0
    private var ringCount = 0

    /// Gravity estimate, removed from every sample so only the strike remains.
    private var gravity: (x: Double, y: Double, z: Double)?
    private var noiseFloor = 0.004
    private var lastRingNote: TimeInterval = 0
    private var lastStrike: TimeInterval = 0
    /// Last time the signal was above the threshold, ringing included.
    private var lastAbove: TimeInterval = 0
    /// Every threshold crossing and what the detector did with it.
    private var strikeLog: [(TimeInterval, Double, String)] = []
    private var pendingCount = 0
    private var groupStarted: TimeInterval = 0
    /// The strike just counted is provisional for its first 60 ms: a knock
    /// is a spike that dips back under the line, while a lift or tilt keeps
    /// the signal above it, and its first crossing counted as a Single tap.
    private var probeStart: TimeInterval = 0
    private var probeAbove = 0
    private var probeTotal = 0
    private var probeActive = false
    private var probePriorStrike: TimeInterval = 0
    private var probePriorGroupStarted: TimeInterval = 0
    private var probePeak: Double = 0
    /// The last ~10 ms of samples in the probe window.
    private var probeTail: [Double] = []

    // Raw capture, written to /tmp by the taptrace debug hook.
    private var traceMags: [Double] = []
    private var traceTimes: [Double] = []
    private var traceDeadline = 0.0
    private var tracePath = ""

    #if DEBUG
    /// Records every sample's residual magnitude for `seconds`, then writes a
    /// summary plus the above-floor events so thresholds can be read off real
    /// taps rather than guessed.
    func startTrace(seconds: Double, path: String) {
        lock.lock(); defer { lock.unlock() }
        traceMags.removeAll(keepingCapacity: true)
        traceTimes.removeAll(keepingCapacity: true)
        traceMags.reserveCapacity(Int(seconds * 900))
        traceTimes.reserveCapacity(Int(seconds * 900))
        tracePath = path
        traceDeadline = CACurrentMediaTime() + seconds
    }
    #endif

    /// Called with the lock held once the capture window closes.
    private func writeTrace() {
        let mags = traceMags, times = traceTimes
        traceMags.removeAll(keepingCapacity: true)
        traceTimes.removeAll(keepingCapacity: true)
        let path = tracePath
        guard !mags.isEmpty, let t0 = times.first else { return }
        let sorted = mags.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        var out = String(format: "samples=%d span=%.2fs rate=%.0fHz\n",
                         mags.count, times.last! - t0, Double(mags.count) / max(0.001, times.last! - t0))
        out += String(format: "p50=%.4f p90=%.4f p99=%.4f p999=%.4f max=%.4f\n",
                      pct(0.50), pct(0.90), pct(0.99), pct(0.999), sorted.last!)
        // Group contiguous above-floor samples into events.
        let floor = max(0.02, pct(0.99) * 2)
        out += String(format: "eventFloor=%.4f\n", floor)
        var i = 0, events = 0
        while i < mags.count {
            guard mags[i] > floor else { i += 1; continue }
            var peak = mags[i]
            let start = times[i]
            var j = i
            while j < mags.count, times[j] - times[i] < 0.030 {
                peak = max(peak, mags[j]); j += 1
            }
            events += 1
            if events <= 40 {
                out += String(format: "event %2d  t=%+.3fs  peak=%.4fg\n", events, start - t0, peak)
            }
            // Skip a refractory span so one impact is not counted many times.
            while j < mags.count, times[j] - start < 0.120 { j += 1 }
            i = j
        }
        out += "events=\(events)\n"
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // Diagnostics, read by the tapstats debug hook while calibrating.
    private var diagReports = 0
    private var diagStrikes = 0
    private var diagPeak = 0.0

    #if DEBUG
    /// Peak magnitude and counters since the last call, then resets them so a
    /// calibration run shows exactly what one tap produced.
    func drainDiagnostics() -> (reports: Int, strikes: Int, peak: Double, noise: Double, ready: Int) {
        lock.lock(); defer { lock.unlock() }
        let snapshot = (diagReports, diagStrikes, diagPeak, noiseFloor, readyCount)
        diagReports = 0; diagStrikes = 0; diagPeak = 0
        return snapshot
    }
    #endif

    /// A completed gesture waiting to be read by the engine.
    private var readyCount = 0
    private var readyAt: TimeInterval = 0
    private static let readyHoldWindow = 0.25
    /// Measured on a MacBook: a keystroke shakes the chassis at 0.15-0.22 g,
    /// indistinguishable from a deliberate fingertip tap, and keys struck
    /// 200 ms apart would group into a false double tap. Strikes that land
    /// next to real keyboard or click input are therefore discarded.
    /// `secondsSinceLastEventType` reads the session's own event clock and
    /// needs no Accessibility grant.
    private static let inputQuietWindow = 0.35

    private init() {}

    /// True when this Mac publishes the accelerometer at all. Answered
    /// once and kept: the sensor is part of the machine, so it cannot
    /// appear or vanish mid-session, and the lookup is a full IORegistry
    /// match that was being run from inside a 30 Hz view body. The matched
    /// service is released, which the old one-liner never did: one Mach
    /// port reference leaked per call, tens of thousands per session.
    var isAvailable: Bool {
        // Under the lock: the sensor thread asks too, while views ask on main.
        lock.lock()
        let known = availabilityCache
        lock.unlock()
        if let known { return known }
        let found: Bool
        if let service = findAccelerometer() {
            IOObjectRelease(service)
            found = true
        } else {
            found = false
        }
        lock.lock()
        availabilityCache = found
        lock.unlock()
        return found
    }
    private var availabilityCache: Bool?

    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        generation += 1
        let myGen = generation
        // The reopen backoff belongs to one silent stretch, not to the
        // next session hours later.
        consecutiveReopens = 0
        _reportedThisSession = false
        _notResponding = false
        deniedLogged = false
        lock.unlock()

        let t = Thread { [weak self] in
            guard let self else { return }
            // A previous thread may still be closing its device. Opening a
            // second handle while that happens either fails with exclusive
            // access or gets closed out from under us by the old thread's
            // cleanup, which is how "open the calibrator, close it, activate
            // the preset" produced a silent sensor. Wait for it, bounded,
            // before opening again. The wait lives on this thread: on the
            // caller's it froze the UI for up to a second and a half, since
            // every caller is a view appearing or the engine starting.
            let handedOver = self.threadDone.wait(timeout: .now() + 1.5) == .success
            defer {
                // Balance exactly one token. If the wait timed out the old
                // thread's signal is still coming, so this thread must not
                // add a second; otherwise later starts would never wait.
                if handedOver { self.threadDone.signal() }
            }
            guard self.isCurrent(myGen) else { return }
            self.lock.lock(); self.runLoop = CFRunLoopGetCurrent(); self.lock.unlock()
            // IOKit writes reports into this buffer for as long as the callback
            // is registered, so it lives for the whole thread, and each thread
            // has its own.
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            defer { buffer.deallocate() }
            self.installSleepObservers()
            defer { self.removeSleepObservers() }
            while self.isCurrent(myGen) {
                guard let dev = self.openSensor(buffer: buffer) else {
                    self.lock.lock()
                    if self.generation == myGen { self.isRunning = false }
                    let wanted = !self.reasons.isEmpty
                    self.lock.unlock()
                    let message = self.lastError ?? "The chassis sensor could not be opened"
                    if message != self.lastOpenError {
                        self.lastOpenError = message
                        ActivityLog.shared.error("Tap the Mac", message)
                    }
                    // Someone still wants the sensor: try again shortly. Not
                    // on a Mac with no sensor (a Mac mini, an Intel Mac),
                    // where every retry was another thread and another
                    // registry search for as long as a tap preset ran.
                    if wanted && self.isAvailable {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.retryIfWanted() }
                    }
                    return
                }
                self.lastOpenError = nil
                ActivityLog.shared.info("Tap the Mac", "Chassis sensor opened, waiting for reports")
                self.streamState = .starting
                self.wakeAttempts = 0
                var reopen = false
                while self.isCurrent(myGen) && !reopen {
                    CFRunLoopRunInMode(.defaultMode, 0.25, false)
                    // Stopped while the run loop waited: stop() zeroed the
                    // stream stats, and one more keepAlive logged a bogus
                    // park, woke the driver after release, and counted a
                    // reopen that never happened.
                    guard self.isCurrent(myGen) else { break }
                    reopen = self.keepAlive()
                }
                self.closeSensor(dev)
                if reopen { ActivityLog.shared.info("Tap the Mac", "Sensor gone quiet or removed; reopening it") }
            }
        }
        t.name = "com.inputconfig.chassistap"
        t.qualityOfService = .userInteractive
        lock.lock(); thread = t; lock.unlock()
        t.start()
    }

    /// True while the thread started with `gen` is the one that should run.
    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunning && generation == gen
    }

    /// A failed open leaves the reasons in place; start again if they still are.
    private func retryIfWanted() {
        lock.lock()
        let wanted = !reasons.isEmpty && !isRunning
        lock.unlock()
        if wanted { start() }
    }

    func stop() {
        lock.lock()
        isRunning = false
        generation += 1
        gravity = nil
        unitScale = 1.0
        pendingCount = 0
        readyCount = 0
        lastReportAt = 0
        measuredHz = 0
        rateBucketCount = 0
        consecutiveReopens = 0
        let rl = runLoop
        runLoop = nil
        thread = nil
        let restoreInterval = originalReportInterval
        originalReportInterval = nil
        lock.unlock()
        if let rl { CFRunLoopStop(rl) }
        if let restoreInterval, restoreInterval > 0, let driver = findAccelerometerDriver() {
            setProperty(driver, "ReportInterval", restoreInterval)
            IOObjectRelease(driver)
        }
    }

    /// Edge-fire read, mirroring TouchpadService.consumeGesture: returns true
    /// for a short window after a matching gesture so the poll loop sees it.
    func consumeTap(count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard readyCount > 0 else { return false }
        let now = CACurrentMediaTime()
        guard now - readyAt < Self.readyHoldWindow else {
            readyCount = 0
            return false
        }
        return readyCount == count
    }

    // MARK: - Sensor plumbing

    /// Wakes the accelerometer's own driver, and only that one: writing to
    /// every SPU driver used to set the ambient light sensor, the gyro and the
    /// rest to 800 Hz too. Only ReportInterval actually starts the stream; the
    /// two state keys are kept because MacTap's M1 Pro recipe sends them.
    ///
    /// Returns false when the interval writes fail. Since macOS 27 the App
    /// Sandbox refuses them (kIOReturnNotPermitted) unless the app carries the
    /// iokit-user-client-class exception naming AppleSPUHIDDriver; without it
    /// the sensor can still be read while something else has it on.
    @discardableResult
    private func wakeDriver() -> Bool {
        guard let driver = findAccelerometerDriver() else { return false }
        defer { IOObjectRelease(driver) }
        // The interval the driver had before this session, put back on the
        // last release so the IMU does not keep sampling at 800 Hz for nobody.
        lock.lock()
        if originalReportInterval == nil {
            originalReportInterval = propertyUInt32(driver, "ReportInterval").map { Int32(clamping: $0) } ?? 0
        }
        lock.unlock()
        setProperty(driver, "SensorPropertyReportingState", 1)
        setProperty(driver, "SensorPropertyPowerState", 1)
        let first = setProperty(driver, "ReportInterval", Self.wakeIntervalUs)
        let second = setProperty(driver, "ReportInterval", Self.runIntervalUs)
        let failure = first != kIOReturnSuccess ? first : second
        noteWake(failure: failure == kIOReturnSuccess ? nil : failure)
        return failure == kIOReturnSuccess
    }

    /// Records whether the wake went through, and says so in the activity
    /// log once per change instead of on every retry.
    private func noteWake(failure: kern_return_t?) {
        lock.lock()
        // Only a refusal counts as denied; a driver not ready yet (just
        // after a wake) or busy is not macOS blocking the sensor.
        let denied = failure == kIOReturnNotPermitted || failure == kIOReturnNotPrivileged
        let changed = _wakeDenied != denied
        _wakeDenied = denied
        // Said once a session: while another app keeps the sensor on, the
        // flag flips back and forth with every park.
        let say = changed && denied && !deniedLogged
        if say { deniedLogged = true }
        lock.unlock()
        if say, let failure {
            let why = failure == kIOReturnNotPermitted ? "not permitted" : String(format: "0x%x", failure)
            ActivityLog.shared.error("Tap the Mac", "macOS did not allow the motion sensor to be switched on (\(why)). Taps are heard only while the sensor is already on.")
        }
    }

    /// The AppleSPUHIDDriver behind the accelerometer (page 0xFF00, usage 3).
    private func findAccelerometerDriver() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSPUHIDDriver"),
                                           &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let isAccel = (propertyUInt32(service, "PrimaryUsagePage") == Self.vendorUsagePage
                           && propertyUInt32(service, "PrimaryUsage") == Self.accelerometerUsage)
                || propertyBool(service, "dispatchAccel")
            if isAccel {
                return service        // caller releases
            }
            IOObjectRelease(service)
        }
        return nil
    }

    @discardableResult
    private func setProperty(_ service: io_service_t, _ key: String, _ value: Int32) -> kern_return_t {
        var v = value
        guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) else { return kIOReturnNoMemory }
        return IORegistryEntrySetCFProperty(service, key as CFString, number)
    }

    private func propertyUInt32(_ service: io_service_t, _ key: String) -> UInt32? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                        kCFAllocatorDefault, 0) else { return nil }
        return (raw.takeRetainedValue() as? NSNumber)?.uint32Value
    }

    private func propertyBool(_ service: io_service_t, _ key: String) -> Bool {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                        kCFAllocatorDefault, 0) else { return false }
        return (raw.takeRetainedValue() as? NSNumber)?.boolValue ?? false
    }

    private func findAccelerometer() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSPUHIDDevice"),
                                           &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let page = propertyUInt32(service, "PrimaryUsagePage") ?? 0
            let usage = propertyUInt32(service, "PrimaryUsage") ?? 0
            if page == Self.vendorUsagePage && usage == Self.accelerometerUsage {
                return service        // caller releases
            }
            IOObjectRelease(service)
        }
        return nil
    }

    private func openSensor(buffer: UnsafeMutablePointer<UInt8>) -> IOHIDDevice? {
        lastError = nil
        wakeDriver()
        guard let service = findAccelerometer() else {
            lastError = "No chassis accelerometer is published on this Mac"
            return nil
        }
        defer { IOObjectRelease(service) }
        guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
            lastError = "IOHIDDeviceCreate failed"
            return nil
        }
        let rc = IOHIDDeviceOpen(dev, 0)
        guard rc == kIOReturnSuccess else {
            lastError = String(format: "IOHIDDeviceOpen failed (0x%x)%@", rc,
                               rc == kIOReturnNotPrivileged ? ", not privileged" : rc == kIOReturnExclusiveAccess ? ", exclusive access" : "")
            return nil
        }
        lock.lock(); device = dev; lock.unlock()
        setDeviceInterval(dev, Self.runIntervalUs)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, buffer, 64,
                                               chassisTapReportCallback, context)
        IOHIDDeviceRegisterRemovalCallback(dev, chassisTapRemovalCallback, context)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        lock.lock()
        sawReport = false
        deviceRemoved = false
        lastReportAt = CACurrentMediaTime()
        rateBucketStart = lastReportAt
        rateBucketCount = 0
        lock.unlock()
        return dev
    }

    /// The client-side interval. On its own it does nothing (the driver wake
    /// is what starts the stream), but MacTap sets it after every wake and
    /// that is the combination verified on the M1 Pro, so it is set here too.
    private func setDeviceInterval(_ dev: IOHIDDevice, _ us: Int32) {
        var v = us
        if let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
            IOHIDDeviceSetProperty(dev, "ReportInterval" as CFString, number)
        }
    }

    /// Runs on the sensor thread every quarter second. A parked IMU is either
    /// silent or ticking at its idle rate; both get the full 8000 -> 1250
    /// wake again, backing off from a quarter second to two (five while macOS
    /// refuses the wake). A healthy stream gets its interval refreshed every
    /// couple of seconds so the driver never decides it is unwanted. Returns
    /// true when the handle should be reopened: accepted wakes and still no
    /// reports for ten seconds, as after some sleeps, or IOKit removed it.
    private func keepAlive() -> Bool {
        let now = CACurrentMediaTime()
        lock.lock()
        if deviceRemoved { lock.unlock(); return true }
        let seen = sawReport
        let silence = now - lastReportAt
        let hz = measuredHz
        let bucketAge = now - rateBucketStart
        let denied = _wakeDenied
        let sinceWake = now - lastLightWake
        lock.unlock()
        // Rate is only trustworthy once a bucket has completed.
        let parked = !seen || silence > Self.parkedSilence || (bucketAge > 1.0 && hz < Self.parkedRateHz && hz > 0)
        guard parked else {
            if streamState != .streaming {
                ActivityLog.shared.info("Tap the Mac", streamState == .starting ? "Chassis sensor streaming" : "Chassis sensor streaming again")
                streamState = .streaming
                wakeAttempts = 0
                consecutiveReopens = 0
                // Streaming again: whatever wake failed earlier is over.
                lock.lock(); _wakeDenied = false; lock.unlock()
            }
            if sinceWake > 2.0 {
                lightWake()
                lock.lock(); lastLightWake = now; lock.unlock()
            }
            return false
        }
        if streamState == .streaming {
            ActivityLog.shared.info("Tap the Mac", String(format: "Sensor parked (%.0f Hz, quiet %.2f s); waking it", hz, silence))
            streamState = .parked
        }
        // Backing off, 10, 30, 90 s and then every 270 s, while reopening
        // brings nothing back, instead of a close and reopen (two log lines)
        // every 10 s for as long as the editor or a tap preset is open.
        let reopenAfter = Self.reopenAfterSilence * pow(3.0, Double(min(consecutiveReopens, 3)))
        if !denied && silence > reopenAfter && wakeAttempts > 0 {
            consecutiveReopens += 1
            lock.lock()
            if !_reportedThisSession && consecutiveReopens >= 3 && !_notResponding {
                _notResponding = true
                lock.unlock()
                ActivityLog.shared.warning("Tap the Mac", "The motion sensor on this Mac is published but has sent nothing; waking it less often")
            } else {
                lock.unlock()
            }
            return true
        }
        lock.lock(); let quiet = _notResponding; lock.unlock()
        // A sensor that never answered is asked every 30 s, not every 2 s.
        let interval = denied ? Self.deniedRetryInterval
            : (quiet ? 30 : min(2.0, 0.25 * pow(2.0, Double(wakeAttempts))))
        if sinceWake < interval { return false }
        wakeDriver()
        if let dev = device { setDeviceInterval(dev, Self.runIntervalUs) }
        lock.lock(); rewakes += 1; lastLightWake = now; lock.unlock()
        wakeAttempts += 1
        return false
    }

    /// Keeps a healthy stream's interval asserted. Skipped while macOS
    /// refuses the wake.
    private func lightWake() {
        guard !wakeDenied, let driver = findAccelerometerDriver() else { return }
        defer { IOObjectRelease(driver) }
        // A refusal sets the flag again, so the write is not repeated every
        // 2 s while another app keeps the stream going.
        let kr = setProperty(driver, "ReportInterval", Self.runIntervalUs)
        if kr == kIOReturnNotPermitted || kr == kIOReturnNotPrivileged { noteWake(failure: kr) }
    }

    /// Sleep and display sleep both park the SPU. Re-wake on the way back.
    private func installSleepObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let obs = nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                // Read under the lock: the sensor thread replaces `device`
                // when a wake tears the SPU device down and it reopens.
                self.lock.lock()
                let running = self.isRunning
                let dev = self.device
                self.lock.unlock()
                guard running else { return }
                self.wakeDriver()
                if let dev { self.setDeviceInterval(dev, Self.runIntervalUs) }
                self.lock.lock()
                self.gravity = nil
                self.rewakes += 1
                self.lastReportAt = CACurrentMediaTime()
                self.lock.unlock()
            }
            sleepObservers.append(obs)
        }
    }

    private func removeSleepObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in sleepObservers { nc.removeObserver(obs) }
        sleepObservers.removeAll()
    }

    /// Closes the device THIS thread opened. `device` may already point at a
    /// successor's handle if start() raced ahead, so never close through it.
    private func closeSensor(_ dev: IOHIDDevice) {
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(dev, 0)
        lock.lock()
        if device === dev { device = nil }
        lock.unlock()
    }

    fileprivate func noteDeviceRemoved() {
        lock.lock(); deviceRemoved = true; lock.unlock()
    }

    // MARK: - Detection

    fileprivate func handleReport(_ report: UnsafePointer<UInt8>, length: Int) {
        guard length >= Self.reportLength else { return }
        func axis(_ offset: Int) -> Double {
            var v: Int32 = 0
            withUnsafeMutableBytes(of: &v) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: report + offset, count: 4))
            }
            return Double(Int32(littleEndian: v)) / Self.imuScale
        }
        let x = axis(Self.dataOffset), y = axis(Self.dataOffset + 4), z = axis(Self.dataOffset + 8)

        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        lastReportAt = now
        sawReport = true
        _reportedThisSession = true
        _notResponding = false
        rateBucketCount += 1
        if now - rateBucketStart >= 1.0 {
            measuredHz = Double(rateBucketCount) / (now - rateBucketStart)
            rateBucketStart = now
            rateBucketCount = 0
        }
        if now < suppressRealUntil { return }

        // Track gravity slowly, so only the sharp part of a strike survives.
        if var g = gravity {
            let a = 0.002
            g.x += (x - g.x) * a; g.y += (y - g.y) * a; g.z += (z - g.z) * a
            gravity = g
        } else {
            gravity = (x, y, z)
            return
        }
        guard let g = gravity else { return }
        // A resting laptop reads 1 g. If this chip's units differ, rescale so
        // the thresholds below stay in real g; leave it alone when the value
        // is implausible rather than amplify noise.
        let gMag = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        unitScale = (gMag > 0.25 && gMag < 4.0) ? 1.0 / gMag : 1.0
        let dx = x - g.x, dy = y - g.y, dz = z - g.z
        let magnitude = (dx * dx + dy * dy + dz * dz).squareRoot() * unitScale

        record(magnitude: magnitude, now: now)
    }

    /// Stores the sample for the calibrator's plot, then runs the detector.
    /// Call with the lock held. The synthetic-tap test hook feeds this too,
    /// so an injected gesture draws the same spike a real knock does.
    private func record(magnitude: Double, now: Double) {
        var magnitude = magnitude
        #if DEBUG
        // While the synthetic double tap is on the plot, live samples carry
        // on as rest, so a real bump never lands beside it in a screenshot.
        if now < debugHealthyUntil {
            let i = now * 800
            magnitude = 0.003 + 0.0015 * sin(i * 0.37) * sin(i * 0.011)
        }
        #endif
        ringMag[ringHead] = magnitude
        ringTime[ringHead] = now
        ringHead = (ringHead + 1) % Self.ringCapacity
        if ringCount < Self.ringCapacity { ringCount += 1 }
        processSample(magnitude: magnitude, now: now)
    }

    /// Strike detection and grouping. Call with the lock held.
    private func processSample(magnitude: Double, now: Double) {
        diagReports += 1
        if magnitude > diagPeak { diagPeak = magnitude }
        if traceDeadline > 0 {
            if now < traceDeadline {
                traceMags.append(magnitude); traceTimes.append(now)
            } else {
                traceDeadline = 0
                writeTrace()
            }
        }
        let threshold = max(minPeak, noiseFloor * Self.snrMultiplier)

        if probeActive {
            probeTotal += 1
            if magnitude > threshold { probeAbove += 1 }
            probePeak = max(probePeak, magnitude)
            probeTail.append(magnitude)
            if probeTail.count > 8 { probeTail.removeFirst() }
            if now - probeStart >= 0.06 {
                probeActive = false
                // Mostly above the line and still high at the end: handling,
                // not a knock. A knock rings and decays, so a firm one (or
                // any knock with the line set low) stays above the line for
                // most of the window too, but its tail has died down.
                let tail = probeTail.isEmpty ? 0 : probeTail.reduce(0, +) / Double(probeTail.count)
                if probeTotal >= 8, Double(probeAbove) / Double(probeTotal) > 0.6,
                   tail > threshold, tail > probePeak * 0.5,
                   pendingCount > 0, lastStrike == probeStart {
                    pendingCount -= 1
                    diagStrikes -= 1
                    lastStrike = probePriorStrike
                    if pendingCount == 0 { groupStarted = probePriorGroupStarted }
                    // The strike's own entry becomes gray, not a second dot
                    // next to a green "counted" one.
                    if let i = strikeLog.lastIndex(where: { $0.0 == probeStart }) {
                        strikeLog[i].2 = "sustained"
                    } else {
                        note(now, magnitude, "sustained")
                    }
                }
            }
        }

        if magnitude > threshold {
            // Deliberately no extra post-gesture lockout: a gesture commits a
            // full interTapWindow after its last strike, so any lockout counted
            // from the commit would blank out the moment right after it and
            // swallow the second tap of a slightly slow double. The refractory,
            // measured from the strike itself, is what rejects chassis ringing.
            // How long the signal was quiet before this crossing. Read it
            // BEFORE stamping lastAbove, or the ring-down looks like silence.
            let quietFor = now - lastAbove
            lastAbove = now
            // Ring-down is only ring-down if there was a strike to ring from.
            // Without that test, a threshold set into the noise turned every
            // crossing into "ring" for ever and the detector went silent; now
            // it produces visible false taps instead, which is what a
            // too-low threshold should look like in the calibrator.
            if quietFor < Self.quietBeforeStrike && now - lastStrike < Self.ringWindow {
                if now - lastRingNote > Self.ringNoteInterval {
                    lastRingNote = now
                    note(now, magnitude, "ring")  // still the last impact decaying
                }
            } else if quietFor < Self.quietBeforeStrike {
                // Above the line with no quiet before it, long after any
                // strike: a tilt or a lift the gravity tracker has not caught
                // up with, or a threshold set into the noise. Shown in the
                // calibrator, never counted; counting it fired a new tap
                // every 300 ms while the laptop was lifted.
                if now - lastRingNote > Self.ringNoteInterval {
                    lastRingNote = now
                    note(now, magnitude, "sustained")
                }
            } else if now - lastStrike <= Self.refractory {
                note(now, magnitude, "refrac")
            } else if userIsTyping() {
                note(now, magnitude, "typing")
            } else {
                probePriorStrike = lastStrike
                probePriorGroupStarted = groupStarted
                probeStart = now
                probeAbove = 0
                probeTotal = 0
                probeActive = true
                probePeak = magnitude
                probeTail.removeAll(keepingCapacity: true)
                lastStrike = now
                if pendingCount == 0 { groupStarted = now }
                pendingCount += 1
                diagStrikes += 1
                note(now, magnitude, "TAP \(pendingCount)")
                // Commit the instant the ceiling is reached: no dead wait on a
                // triple tap, and tap number four cannot join this gesture.
                if pendingCount >= Self.maxTaps { commit(at: now) }
            }
        } else if now - lastAbove > Self.floorQuietAfterCrossing, magnitude < noiseFloor * 8 {
            // Only genuinely quiet samples shape the noise floor: nothing from
            // the 300 ms after any crossing (the ring-down sat just under the
            // line and used to drag the floor, and with it the threshold, up
            // after every tap), and no lone spike eight times the floor.
            noiseFloor += (magnitude - noiseFloor) * 0.005
        }

        // Otherwise the gesture closes once the taps stop arriving.
        if pendingCount > 0, now - lastStrike > Self.interTapWindow {
            commit(at: now)
        }
    }

    /// Records a threshold crossing for the tapstrikes diagnostic.
    private func note(_ t: TimeInterval, _ peak: Double, _ verdict: String) {
        strikeLog.append((t, peak, verdict))
        if strikeLog.count > 120 { strikeLog.removeFirst() }
    }

    /// Publishes the finished gesture and hard-resets the counter, so nothing
    /// from this gesture can leak into the next one. Call with the lock held.
    private func commit(at now: TimeInterval) {
        readyCount = pendingCount
        readyAt = now
        pendingCount = 0
        commitLog.append((now, readyCount))
        if commitLog.count > 32 { commitLog.removeFirst() }
        let count = readyCount
        let scan = scanCallback
        ActivityLog.shared.event("Tap the Mac", TapCalibrationView.gestureName(count))
        Task { @MainActor in
            ChassisTapActivity.shared.fire(count: count)
            scan?(count)
        }
    }

    /// Every gesture the detector has decided on, for verifying the grouping
    /// rules against controlled input.
    private var commitLog: [(TimeInterval, Int)] = []

    #if DEBUG
    func drainStrikes() -> String {
        lock.lock(); defer { lock.unlock() }
        defer { strikeLog.removeAll(keepingCapacity: true) }
        guard let t0 = strikeLog.first?.0 else { return "(no threshold crossings)" }
        var out = String(format: "threshold=%.4fg  noise=%.4fg\n",
                         max(minPeak, noiseFloor * Self.snrMultiplier), noiseFloor)
        var last = t0
        for (t, peak, verdict) in strikeLog {
            out += String(format: "t=%+7.3fs  (+%5.0fms)  %.4fg  %@\n",
                          t - t0, (t - last) * 1000, peak, verdict)
            last = t
        }
        return out
    }
    #endif

    #if DEBUG
    func drainCommits() -> String {
        lock.lock(); defer { lock.unlock() }
        defer { commitLog.removeAll(keepingCapacity: true) }
        guard let first = commitLog.first?.0 else { return "(no gestures)" }
        return commitLog.map { String(format: "t=%+.3fs -> %d tap%@",
                                      $0.0 - first, $0.1, $0.1 == 1 ? "" : "s") }
            .joined(separator: "\n")
    }
    #endif

    /// True while the keyboard or a click is in use, so the shock of a
    /// keystroke is not read as a tap. Only consulted when a candidate strike
    /// clears the threshold, so it stays off the 800 Hz hot path.
    private func userIsTyping() -> Bool {
        if injecting { return false }
        // The session's counters include this app's own posted clicks and
        // keys, so a running auto-clicker, a repeating key or a stick
        // scrolling made every knock read as typing, and an auto-clicker
        // started by a tap could not be stopped by one. An event that lines
        // up with the app's last post is the app's own.
        let now = ProcessInfo.processInfo.systemUptime
        for type in [CGEventType.keyDown, .flagsChanged, .leftMouseDown,
                     .rightMouseDown, .otherMouseDown, .scrollWheel] {
            let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                eventType: type)
            guard since < Self.inputQuietWindow else { continue }
            if abs((now - since) - InputSimulator.lastPostUptime(of: type)) < 0.03 { continue }
            return true
        }
        return false
    }

    /// Set while synthetic taps are being pushed through, so the typing guard
    /// does not reject them just because a test harness is driving the machine.
    private var injecting = false
    /// Real reports are ignored until this time while a synthetic gesture is
    /// being replayed, so a physical tap cannot interleave with the test clock.
    private var suppressRealUntil: TimeInterval = 0

    #if DEBUG
    /// Test hook: pushes `count` synthetic impacts through the real detector at
    /// realistic spacing, so the grouping and hand-off can be verified without
    /// physically striking the machine. Not reachable outside DEBUG builds.
    func injectSyntheticTaps(count: Int, spacing: Double = 0.15) {
        lock.lock(); defer { lock.unlock() }
        injecting = true
        defer { injecting = false }
        lastStrike = 0
        pendingCount = 0
        let base = CACurrentMediaTime()
        let strong = max(minPeak, noiseFloor * Self.snrMultiplier) * 3
        // Walk time at the real report interval, feeding quiet samples between
        // the strikes. The detector closes a gesture on elapsed time, and only
        // ever sees time pass when a sample arrives, so a faithful test has to
        // reproduce the continuous 800 Hz stream rather than jump between taps.
        lastAbove = 0
        let step = Double(Self.runIntervalUs) / 1_000_000
        let end = Double(count - 1) * spacing + Self.interTapWindow + 0.05
        var next = 0
        var t = 0.0
        while t <= end {
            // Replay each tap with the ring-down a real strike produces:
            // ~85 ms of decaying lobes that repeatedly re-cross the threshold.
            // Without this the test is easier than reality and hides exactly
            // the double-counting this detector has to survive.
            let sinceTap = t - Double(max(0, next - 1)) * spacing
            if next < count, t >= Double(next) * spacing {
                record(magnitude: strong, now: base + t)
                next += 1
            } else if next > 0, sinceTap < 0.085 {
                let decay = exp(-sinceTap / 0.035)
                let lobe = abs(sin(2 * Double.pi * sinceTap / 0.012))
                record(magnitude: strong * decay * lobe, now: base + t)
            } else {
                record(magnitude: 0.001, now: base + t)
            }
            t += step
        }
        suppressRealUntil = base + t + 0.10
        lastStrike = 0
        pendingCount = 0
        lastAbove = 0
        // commit() stamped readyAt with the synthetic clock, which runs ahead
        // of the real one. Leaving it there makes consumeTap see a negative age
        // and hold the gesture ready for far longer than a real tap would.
        readyAt = CACurrentMediaTime()
    }
    #endif
}

// MARK: - Calibration API (used by TapCalibrationView)

extension ChassisTapService {
    struct Snapshot {
        var running: Bool
        var available: Bool
        var hz: Double
        var silence: Double
        var parked: Bool
        var rewakes: Int
        /// macOS refused to switch the sensor on (see wakeDriver()).
        var wakeDenied: Bool
        /// Published but silent through several reopens.
        var notResponding: Bool
        var gravityMagnitude: Double
        var noiseFloor: Double
        var minPeak: Double
        var threshold: Double
        /// (time, magnitude) for the last few seconds, oldest first.
        var samples: [(Double, Double)]
        var error: String?
        /// (time, peak, verdict) threshold crossings, oldest first.
        var strikes: [(Double, Double, String)]
        /// (time, count) finished gestures, oldest first.
        var gestures: [(Double, Int)]
        var now: Double
    }

    /// Everything the calibrator draws, copied under the lock. The sample
    /// window is a few seconds at ~800 Hz, so this is a few thousand doubles
    /// thirty times a second, which is nothing.
    func calibrationSnapshot(window: Double = 4.0) -> Snapshot {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        var samples: [(Double, Double)] = []
        samples.reserveCapacity(ringCount)
        let start = (ringHead - ringCount + Self.ringCapacity) % Self.ringCapacity
        for i in 0..<ringCount {
            let idx = (start + i) % Self.ringCapacity
            if now - ringTime[idx] <= window { samples.append((ringTime[idx], ringMag[idx])) }
        }
        let gMag = gravity.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() } ?? 0
        var silence = lastReportAt > 0 ? now - lastReportAt : 0
        var hz = measuredHz, running = isRunning, available = device != nil
        #if DEBUG
        // Marketing capture: report a healthy 800 Hz stream for a moment after
        // a synthetic tap, so the calibrator's plot keeps drawing.
        if now < debugHealthyUntil { silence = 0; hz = 800; running = true; available = true }
        #endif
        return Snapshot(running: running,
                        available: available,
                        hz: hz,
                        silence: silence,
                        parked: running && (silence > Self.parkedSilence || (hz > 0 && hz < Self.parkedRateHz)),
                        rewakes: rewakes,
                        wakeDenied: _wakeDenied,   // already under the lock here
                        notResponding: _notResponding,
                        gravityMagnitude: gMag,
                        noiseFloor: noiseFloor,
                        minPeak: minPeak,
                        threshold: max(minPeak, noiseFloor * Self.snrMultiplier),
                        samples: samples,
                        error: _lastError,   // already under the lock here
                        strikes: strikeLog.filter { now - $0.0 <= window },
                        gestures: commitLog.filter { now - $0.0 <= window },
                        now: now)
    }

    #if DEBUG
    /// Marketing capture only: write two seconds of quiet samples with two
    /// knocks into the plot buffer, log them as a counted double tap, and
    /// mark the stream healthy, so the calibrator can be photographed in
    /// use without anyone knocking on the Mac.
    func debugInjectDoubleTap() {
        let now = CACurrentMediaTime()
        lock.lock()
        let hz = 800.0; let start = now - 2.0
        let knocks: [(Double, Double)] = [(now - 0.95, 0.42), (now - 0.60, 0.37)]
        var i = 0
        while true {
            let t = start + Double(i) / hz
            if t > now { break }
            var mag = 0.003 + 0.0015 * sin(Double(i) * 0.37) * sin(Double(i) * 0.011)
            for (kt, peak) in knocks where t >= kt {
                let dt = t - kt
                mag += peak * exp(-dt / 0.025) * abs(cos(dt * 2 * .pi * 90))
            }
            ringMag[ringHead] = mag; ringTime[ringHead] = t
            ringHead = (ringHead + 1) % Self.ringCapacity
            ringCount = min(ringCount + 1, Self.ringCapacity)
            i += 1
        }
        strikeLog.append((knocks[0].0, knocks[0].1, "TAP 1"))
        strikeLog.append((knocks[1].0, knocks[1].1, "TAP 2"))
        commitLog.append((knocks[1].0 + 0.05, 2))
        lastReportAt = now; measuredHz = hz
        debugHealthyUntil = now + 6
        lock.unlock()
        Task { @MainActor in ChassisTapActivity.shared.fire(count: 2) }
    }
    #endif

    /// The user-set threshold floor, in g. Persisted; takes effect at once.
    var thresholdFloor: Double {
        get { lock.lock(); defer { lock.unlock() }; return minPeak }
        set {
            let v = min(1.0, max(0.01, newValue))
            lock.lock(); minPeak = v; lock.unlock()
            UserDefaults.standard.set(v, forKey: Self.minPeakKey)
        }
    }

    func resetThresholdFloor() { thresholdFloor = Self.defaultMinPeak }
}

private func chassisTapReportCallback(context: UnsafeMutableRawPointer?,
                                      result: IOReturn,
                                      sender: UnsafeMutableRawPointer?,
                                      type: IOHIDReportType,
                                      reportID: UInt32,
                                      report: UnsafeMutablePointer<UInt8>,
                                      reportLength: CFIndex) {
    guard let context else { return }
    let service = Unmanaged<ChassisTapService>.fromOpaque(context).takeUnretainedValue()
    service.handleReport(report, length: Int(reportLength))
}

/// IOKit tore the device down (sleep, driver restart). The sensor thread's
/// keepAlive sees the flag and closes and reopens the handle.
private func chassisTapRemovalCallback(context: UnsafeMutableRawPointer?,
                                       result: IOReturn,
                                       sender: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let service = Unmanaged<ChassisTapService>.fromOpaque(context).takeUnretainedValue()
    service.noteDeviceRemoved()
}
