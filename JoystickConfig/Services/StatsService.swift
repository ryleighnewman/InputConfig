import Foundation
import Combine

/// Persistent usage telemetry for JoystickConfig. Tracks how much time the
/// user spends with controllers connected, which presets they activate
/// most, what buttons they push, total mouse / scroll / MIDI output volume,
/// and similar trivia. Everything is local - nothing is sent over the
/// network.
///
/// Storage: a single `stats.json` next to the presets directory. Reads
/// happen on init; writes are coalesced through the persist queue every
/// few seconds so the 120 Hz mapping loop never serializes JSON on its
/// hot path.
/// Not @MainActor - the engine and GameControllerService already hop to
/// the main actor before calling the recording methods, and the singleton
/// itself is nonisolated so it can be shared across the whole app.
final class StatsService: ObservableObject, @unchecked Sendable {

    // MARK: - Persisted state

    struct PersistentStats: Codable {
        var firstLaunchAt: Date = Date()
        var launchCount: Int = 0
        var totalConnectedTime: TimeInterval = 0
        var totalEngineRunningTime: TimeInterval = 0
        var presetActivationCount: Int = 0
        var presetTimeByName: [String: TimeInterval] = [:]
        var presetActivationCountByName: [String: Int] = [:]
        var totalButtonPresses: Int = 0
        var totalKeyPresses: Int = 0
        var totalMouseClicks: Int = 0
        var totalMidiEvents: Int = 0
        var totalMouseMotionPixels: Int = 0
        var totalScrollTicks: Int = 0
        var totalTouchpadFingerEvents: Int = 0
        var totalMacroExecutions: Int = 0
        /// Daily connection log - `yyyy-MM-dd` → seconds connected that day.
        var dailyConnectedSeconds: [String: TimeInterval] = [:]
        /// "btn 5" / "axi 0 +" / "tpr <id>" → press counter.
        var inputPressCounts: [String: Int] = [:]
        /// Controller display name → cumulative connected seconds.
        var controllerTimeByName: [String: TimeInterval] = [:]
        /// Controller display name → connection event count.
        var controllerConnectionCount: [String: Int] = [:]
    }

    @Published private(set) var stats = PersistentStats()

    // MARK: - Lifetime / lifecycle

    nonisolated(unsafe) static let shared = StatsService()

    private let fileURL: URL
    private let persistQueue = DispatchQueue(label: "com.joystickconfig.stats-io", qos: .utility)
    private var flushTimer: Timer?
    /// True while we have at least one controller connected. Drives the
    /// "total connected time" accumulator.
    private var connectedSince: Date?
    /// True while MappingEngine is running with an active preset.
    private var engineRunningSince: Date?
    private var activePresetName: String?
    private var activePresetStartedAt: Date?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("JoystickConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("stats.json")
        load()
        stats.launchCount += 1
        startFlushTimer()
    }

    // MARK: - Recording API

    func controllerConnected(name: String) {
        if connectedSince == nil { connectedSince = Date() }
        stats.controllerConnectionCount[name, default: 0] += 1
        markDirty()
    }

    /// Called when the last controller disconnects.
    func controllerDisconnected(name: String, anyStillConnected: Bool) {
        // Flush per-name time only if we know how long the last connection
        // lasted. We don't track per-controller start, only the overall
        // connectedSince - so apportion by an estimate: 0 here, the rolling
        // accumulator continues until ALL are gone.
        _ = name
        if !anyStillConnected, let since = connectedSince {
            let delta = Date().timeIntervalSince(since)
            stats.totalConnectedTime += delta
            recordDailyConnection(delta: delta)
            connectedSince = nil
            // Apportion this run's seconds to whatever controller name
            // last connected: cheap approximation.
            stats.controllerTimeByName[name, default: 0] += delta
        }
        markDirty()
    }

    func enginStarted(presetName: String) {
        engineRunningSince = Date()
        activePresetName = presetName
        activePresetStartedAt = Date()
        stats.presetActivationCount += 1
        stats.presetActivationCountByName[presetName, default: 0] += 1
        markDirty()
    }

    func engineStopped() {
        if let s = engineRunningSince {
            stats.totalEngineRunningTime += Date().timeIntervalSince(s)
            engineRunningSince = nil
        }
        if let name = activePresetName, let s = activePresetStartedAt {
            stats.presetTimeByName[name, default: 0] += Date().timeIntervalSince(s)
        }
        activePresetName = nil
        activePresetStartedAt = nil
        markDirty()
    }

    func recordButtonPress(inputKey: String) {
        stats.totalButtonPresses += 1
        stats.inputPressCounts[inputKey, default: 0] += 1
    }

    func recordKeyPress() { stats.totalKeyPresses += 1 }
    func recordMouseClick() { stats.totalMouseClicks += 1 }
    func recordMidiEvent() { stats.totalMidiEvents += 1 }
    func recordMouseMotion(pixels: Int) { stats.totalMouseMotionPixels += abs(pixels) }
    func recordScroll(ticks: Int) { stats.totalScrollTicks += abs(ticks) }
    func recordTouchpadEvent() { stats.totalTouchpadFingerEvents += 1 }
    func recordMacroExecution() { stats.totalMacroExecutions += 1 }

    // MARK: - Derived

    var topPresets: [(name: String, count: Int)] {
        stats.presetActivationCountByName
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { ($0.key, $0.value) }
    }

    var topInputs: [(key: String, count: Int)] {
        stats.inputPressCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { ($0.key, $0.value) }
    }

    var topControllers: [(name: String, time: TimeInterval)] {
        stats.controllerTimeByName
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { ($0.key, $0.value) }
    }

    var daysTracked: Int {
        max(1, Int(Date().timeIntervalSince(stats.firstLaunchAt) / 86_400))
    }

    /// Last 14 days of connected seconds, oldest first. Missing days
    /// (no activity) report 0.
    var last14DaysConnected: [(date: Date, seconds: TimeInterval)] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [(Date, TimeInterval)] = []
        for offset in (0..<14).reversed() {
            let d = cal.date(byAdding: .day, value: -offset, to: today)!
            let key = fmt.string(from: d)
            out.append((d, stats.dailyConnectedSeconds[key] ?? 0))
        }
        return out
    }

    func resetAll() {
        stats = PersistentStats()
        connectedSince = nil
        engineRunningSince = nil
        activePresetName = nil
        activePresetStartedAt = nil
        flushNow()
    }

    // MARK: - Persistence

    private var dirty = false
    private func markDirty() { dirty = true }

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushIfDirty() }
        }
        if let t = flushTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func flushIfDirty() {
        guard dirty else { return }
        // Roll up any in-flight time so a crash before disconnect doesn't
        // throw away the session.
        if let since = connectedSince {
            stats.totalConnectedTime += Date().timeIntervalSince(since)
            connectedSince = Date()
        }
        if let s = engineRunningSince {
            stats.totalEngineRunningTime += Date().timeIntervalSince(s)
            engineRunningSince = Date()
        }
        if let name = activePresetName, let s = activePresetStartedAt {
            stats.presetTimeByName[name, default: 0] += Date().timeIntervalSince(s)
            activePresetStartedAt = Date()
        }
        flushNow()
    }

    private func flushNow() {
        let snapshot = stats
        let url = fileURL
        persistQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        dirty = false
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistentStats.self, from: data) else {
            return
        }
        stats = decoded
    }

    private func recordDailyConnection(delta: TimeInterval) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let key = fmt.string(from: Date())
        stats.dailyConnectedSeconds[key, default: 0] += delta
    }
}
