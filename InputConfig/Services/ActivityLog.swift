import Foundation
import AppKit

/// The app-wide activity log behind the developer log at the bottom of the
/// main window and its pop-out window. Every service posts the moments that
/// matter for diagnosing a problem: controllers arriving and leaving, the
/// engine starting a preset, presses and releases, permission changes,
/// helper processes, the chassis sensor, MIDI, the emergency stop, and
/// anything that fails. Entries carry a level and a source so the view can
/// colour them, count problems, and filter, and `report()` turns the lot
/// into one text file a user can send.
///
/// `post` is safe from any thread (the sensor thread and HID callbacks use
/// it). Entries are batched and published on the main thread at 5 Hz so the
/// UI never re-renders per input event.
final class ActivityLog: ObservableObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = ActivityLog()

    enum Level: Int, Comparable, Sendable {
        case info, event, warning, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .info: return "info"
            case .event: return "event"
            case .warning: return "warning"
            case .error: return "error"
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let id: Int
        let time: Date
        let level: Level
        let source: String
        let text: String
        /// Controller slot the entry belongs to, for per-controller colour.
        let slot: Int?
    }

    /// Everything currently kept, oldest first. Capped at `capacity`.
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var warningCount = 0
    @Published private(set) var errorCount = 0
    /// Bumps whenever `entries` is replaced, for cheap onChange hooks.
    @Published private(set) var revision = 0

    static let capacity = 2000

    private let lock = NSLock()
    private var pending: [Entry] = []
    private var nextID = 1

    private init() {}

    /// Set while a flush is scheduled, so a burst of posts schedules one.
    /// Touched only under `lock`.
    private var flushScheduled = false

    // MARK: - Posting

    nonisolated func post(_ level: Level, _ source: String, _ text: String, slot: Int? = nil) {
        lock.lock()
        let entry = Entry(id: nextID, time: Date(), level: level, source: source, text: text, slot: slot)
        nextID += 1
        pending.append(entry)
        if pending.count > Self.capacity { pending.removeFirst(pending.count - Self.capacity) }
        // One flush is scheduled per burst, 200 ms out, rather than a timer
        // that fired five times a second for the life of the process with
        // nothing to do. An idle app now posts nothing and wakes for nothing.
        let schedule = !flushScheduled
        if schedule { flushScheduled = true }
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
        #if DEBUG
        if level >= .warning { print("[\(source)] \(level.label): \(text)") }
        #endif
    }

    nonisolated func info(_ source: String, _ text: String, slot: Int? = nil) { post(.info, source, text, slot: slot) }
    nonisolated func event(_ source: String, _ text: String, slot: Int? = nil) { post(.event, source, text, slot: slot) }
    nonisolated func warning(_ source: String, _ text: String, slot: Int? = nil) { post(.warning, source, text, slot: slot) }
    nonisolated func error(_ source: String, _ text: String, slot: Int? = nil) { post(.error, source, text, slot: slot) }

    @MainActor
    func clear() {
        lock.lock(); pending.removeAll(); lock.unlock()
        entries.removeAll()
        warningCount = 0
        errorCount = 0
        revision &+= 1
    }

    @MainActor
    private func flush() {
        lock.lock()
        flushScheduled = false
        guard !pending.isEmpty else { lock.unlock(); return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        entries.append(contentsOf: batch)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        for e in batch {
            if e.level == .warning { warningCount += 1 }
            if e.level == .error { errorCount += 1 }
        }
        revision &+= 1
    }

    // MARK: - Report

    /// A complete diagnostic text: the machine, the app, what is connected,
    /// the permissions and settings that usually explain a problem, then the
    /// log. Meant to be attached to a bug report as-is.
    @MainActor
    func report(controllers: [(slot: Int, info: ControllerInfo)],
                engineRunning: Bool, activePreset: String?, pollHz: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var out = "InputConfig \(version) (\(build)) activity report\n"
        out += "Generated \(f.string(from: Date()))\n"
        out += "macOS \(os), \(Self.hardwareModel())\n\n"

        out += "Accessibility access: \(AXIsProcessTrusted() ? "granted" : "NOT granted")\n"
        out += "Engine: \(engineRunning ? "running" : "stopped")"
        if let activePreset { out += ", preset \"\(activePreset)\"" }
        if engineRunning { out += ", \(pollHz) Hz" }
        out += "\n"

        if controllers.isEmpty {
            out += "Controllers: none\n"
        } else {
            for c in controllers {
                var caps: [String] = []
                if c.info.supportsMotion { caps.append("motion") }
                if c.info.hasLight { caps.append("light bar") }
                if c.info.hasTouchpad { caps.append("touchpad") }
                if c.info.hasBattery, let b = c.info.batteryLevel { caps.append("battery \(Int(b * 100))%") }
                out += "Controller \(c.slot): \(c.info.name) (\(c.info.productCategory)), \(c.info.buttonCount) buttons, \(c.info.axisCount) axes"
                if !caps.isEmpty { out += ", " + caps.joined(separator: ", ") }
                out += "\n"
            }
        }

        let d = UserDefaults.standard
        let stop = EmergencyStopService.shared
        out += "Emergency stop: shortcut \(stop.isEnabled ? stop.spec.displayString : "off")"
        out += ", controller hold \(stop.controllerHoldEnabled ? "button \(stop.controllerButton) for \(stop.holdSeconds) s" : "off")\n"
        out += "Settings: dock icon \(d.object(forKey: "InputConfig.showDockIcon") as? Bool ?? true), "
        out += "menu bar icon \(d.object(forKey: "InputConfig.showMenuBarIcon") as? Bool ?? true), "
        out += "text size \(d.integer(forKey: "InputConfig.a11y.textSize")), "
        out += "reduce motion \(d.bool(forKey: "InputConfig.a11y.reduceMotion")), "
        out += "reduce transparency \(d.bool(forKey: "InputConfig.a11y.reduceTransparency"))\n"

        let tap = ChassisTapService.shared.calibrationSnapshot(window: 1)
        out += "Chassis tap sensor: \(tap.running ? "streaming \(Int(tap.hz)) Hz" : (tap.error ?? "not running"))"
        if tap.rewakes > 0 { out += ", re-woken \(tap.rewakes)x" }
        out += "\n"

        out += "\nLog (\(entries.count) entries, \(warningCount) warnings, \(errorCount) errors)\n"
        out += String(repeating: "-", count: 72) + "\n"
        for e in entries {
            let slot = e.slot.map { " [slot \($0)]" } ?? ""
            out += "\(f.string(from: e.time))  \(e.level.label.padding(toLength: 7, withPad: " ", startingAt: 0))  \(e.source)\(slot): \(e.text)\n"
        }
        return out
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
