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

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(byKey) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Identity

    /// Stable per-controller identity key. Apple's Game Controller framework
    /// does NOT expose hardware serial numbers, so two physically identical
    /// controllers share a key. That's fine - they have the same drift
    /// characteristics anyway.
    static func identityKey(for controller: GCController) -> String {
        let vendor = controller.vendorName ?? "Controller"
        let category = controller.productCategory
        return "\(vendor)|\(category)"
    }

    // MARK: - Public API

    func calibration(forKey key: String) -> MotionCalibration? {
        lock.lock(); defer { lock.unlock() }
        return byKey[key]
    }

    func isCalibrated(forKey key: String) -> Bool {
        calibration(forKey: key) != nil
    }

    func save(_ calibration: MotionCalibration) {
        lock.lock()
        byKey[calibration.controllerKey] = calibration
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
        return table?[key]
    }

    func setRezeroButton(_ index: Int?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        var table = (UserDefaults.standard.dictionary(forKey: Self.rezeroButtonsKey) as? [String: Int]) ?? [:]
        table[key] = index
        UserDefaults.standard.set(table, forKey: Self.rezeroButtonsKey)
    }

    /// Subtract the stored drift from a raw gyro value. Returns the value
    /// unchanged if the controller hasn't been calibrated yet - better to
    /// have uncorrected motion than no motion.
    /// Move the stored gyro drift a little toward what a resting controller
    /// is reading right now. Called from the poll loop only after the
    /// controller has been still for a while, so the zero follows the
    /// sensor's slow thermal wander without anyone pressing anything.
    /// Written to disk at most every few seconds.
    private var lastDriftSave: CFTimeInterval = 0
    func nudgeGyroDrift(dx: Float, dy: Float, dz: Float, forKey key: String) {
        lock.lock()
        var cal = byKey[key] ?? MotionCalibration(controllerKey: key,
                                                  gyroDriftX: 0, gyroDriftY: 0, gyroDriftZ: 0,
                                                  accelDriftX: 0, accelDriftY: 0, accelDriftZ: 0,
                                                  savedAt: Date())
        cal.gyroDriftX += dx; cal.gyroDriftY += dy; cal.gyroDriftZ += dz
        byKey[key] = cal
        let now = CACurrentMediaTime()
        let due = now - lastDriftSave > 5
        if due { lastDriftSave = now }
        lock.unlock()
        if due { saveToDisk() }
    }

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

/// Reads the MacBook's own accelerometer and turns a physical tap on the case
/// into a bindable input, so someone who cannot reach a button can tap the
/// laptop instead.
///
/// The sensor is an HID device published by the SPU (sensor processing unit)
/// on M2 and later, and on M1 Pro / Max / Ultra. Two things about it are not
/// obvious:
///
///  1. Opening the device succeeds but delivers ZERO reports until the driver
///     is woken. The wake is a property write on the `AppleSPUHIDDriver`
///     registry service. Writing it on the opened client device does nothing.
///  2. Under the App Store sandbox this needs `com.apple.security.device.usb`,
///     which this app already declares. Sandbox alone is not enough.
///
/// Verified on an M4 Max: ~800 Hz, 4027 reports in 5 s, sandboxed.
/// The service names are not in any public SDK header, so every step fails
/// softly and the feature simply does not appear when the sensor is absent.
///
///  3. The wake does not stick. When the chassis is still, macOS parks the
///     IMU: the HID device stays open and simply stops delivering, or drops
///     to a ~100 Hz idle rate that misses a 10 ms knock outright. A single
///     wake at open therefore works on a machine that is handled right after
///     activation and fails on one that sat still first, which is how an
///     M1 Pro that publishes the sensor produced no taps at all. The run loop
///     now measures silence and rate and re-runs the full wake whenever the
///     stream looks parked, and again after the Mac wakes from sleep.
/// Main-thread mirror of tap gestures for views: rows light up on a knock
/// the way they do on a button, with or without a preset running.
@MainActor
final class ChassisTapActivity: ObservableObject {
    static let shared = ChassisTapActivity()
    /// Serialized input keys ("cht 2") that just fired, held for a moment.
    @Published private(set) var activeKeys: Set<String> = []
    private static let hold = 0.45

    fileprivate func fire(count: Int) {
        let key = "cht \(count)"
        activeKeys.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold) { [weak self] in
            self?.activeKeys.remove(key)
        }
    }
}

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
        let wasEmpty = reasons.isEmpty
        reasons.insert(reason)
        lock.unlock()
        if wasEmpty { start() }
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
    private var minPeak: Double = {
        let v = UserDefaults.standard.double(forKey: ChassisTapService.minPeakKey)
        return v > 0 ? v : ChassisTapService.defaultMinPeak
    }()
    /// Stream health: a parked IMU shows up as silence or a low rate.
    private static let parkedSilence = 0.25
    private static let parkedRateHz = 450.0
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
    /// Signalled when the sensor thread has fully exited; starts as signalled
    /// so the first start() does not wait.
    private let threadDone: DispatchSemaphore = { let s = DispatchSemaphore(value: 0); s.signal(); return s }()
    private var device: IOHIDDevice?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// IOKit writes incoming reports into this pointer for as long as the
    /// callback is registered, so it must outlive the registration call. A
    /// buffer borrowed inside withUnsafeMutableBufferPointer dangles the
    /// moment that closure returns, and reports land on freed memory.
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private(set) var isRunning = false

    // Stream health, kept under the lock.
    private var lastReportAt: TimeInterval = 0
    private var rateBucketStart: TimeInterval = 0
    private var rateBucketCount = 0
    private var measuredHz = 0.0
    private var lastLightWake: TimeInterval = 0
    private var rewakes = 0
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
        if let known = availabilityCache { return known }
        let found: Bool
        if let service = findAccelerometer() {
            IOObjectRelease(service)
            found = true
        } else {
            found = false
        }
        availabilityCache = found
        return found
    }
    private var availabilityCache: Bool?

    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
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
            self.runLoop = CFRunLoopGetCurrent()
            guard let dev = self.openSensor() else {
                self.lock.lock(); self.isRunning = false; self.lock.unlock()
                ActivityLog.shared.error("Tap the Mac", self.lastError ?? "The chassis sensor could not be opened")
                return
            }
            ActivityLog.shared.info("Tap the Mac", "Chassis sensor streaming")
            self.installSleepObservers()
            while self.isRunning {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
                self.keepAlive()
            }
            self.removeSleepObservers()
            self.closeSensor(dev)
        }
        t.name = "com.inputconfig.chassistap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        isRunning = false
        gravity = nil
        unitScale = 1.0
        pendingCount = 0
        readyCount = 0
        lastReportAt = 0
        measuredHz = 0
        rateBucketCount = 0
        lock.unlock()
        if let rl = runLoop { CFRunLoopStop(rl) }
        thread = nil
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

    private func wakeDriver() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSPUHIDDriver"),
                                           &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            setProperty(service, "SensorPropertyReportingState", 1)
            setProperty(service, "SensorPropertyPowerState", 1)
            setProperty(service, "ReportInterval", Self.wakeIntervalUs)
            setProperty(service, "ReportInterval", Self.runIntervalUs)
            IOObjectRelease(service)
        }
    }

    private func setProperty(_ service: io_service_t, _ key: String, _ value: Int32) {
        var v = value
        if let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
            IORegistryEntrySetCFProperty(service, key as CFString, number)
        }
    }

    private func propertyUInt32(_ service: io_service_t, _ key: String) -> UInt32? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                        kCFAllocatorDefault, 0) else { return nil }
        return (raw.takeRetainedValue() as? NSNumber)?.uint32Value
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

    private func openSensor() -> IOHIDDevice? {
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
        IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 64,
                                               chassisTapReportCallback, context)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        lock.lock()
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
    /// wake again. A healthy stream gets a light state refresh every couple
    /// of seconds so the driver never decides it is unwanted.
    private func keepAlive() {
        let now = CACurrentMediaTime()
        lock.lock()
        let silence = now - lastReportAt
        let hz = measuredHz
        let bucketAge = now - rateBucketStart
        lock.unlock()
        // Rate is only trustworthy once a bucket has completed.
        let parked = silence > Self.parkedSilence || (bucketAge > 1.0 && hz < Self.parkedRateHz && hz > 0)
        if parked {
            wakeDriver()
            if let dev = device { setDeviceInterval(dev, Self.runIntervalUs) }
            lock.lock(); rewakes += 1; lastLightWake = now; lock.unlock()
            ActivityLog.shared.info("Tap the Mac", String(format: "Sensor parked (%.0f Hz, quiet %.2f s); woken again", hz, silence))
        } else if now - lastLightWake > 2.0 {
            lightWake()
            lock.lock(); lastLightWake = now; lock.unlock()
        }
    }

    /// Reporting and power state only; no interval bump, so a healthy stream
    /// is not disturbed.
    private func lightWake() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSPUHIDDriver"),
                                           &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            setProperty(service, "SensorPropertyReportingState", 1)
            setProperty(service, "SensorPropertyPowerState", 1)
            IOObjectRelease(service)
        }
    }

    /// Sleep and display sleep both park the SPU. Re-wake on the way back.
    private func installSleepObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let obs = nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.wakeDriver()
                if let dev = self.device { self.setDeviceInterval(dev, Self.runIntervalUs) }
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
            } else if now - lastStrike <= Self.refractory {
                note(now, magnitude, "refrac")
            } else if userIsTyping() {
                note(now, magnitude, "typing")
            } else {
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
        for type in [CGEventType.keyDown, .flagsChanged, .leftMouseDown,
                     .rightMouseDown, .otherMouseDown, .scrollWheel] {
            let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                eventType: type)
            if since < Self.inputQuietWindow { return true }
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
