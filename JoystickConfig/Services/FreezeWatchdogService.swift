import Foundation
import AppKit

/// Background watchdog that detects when the main thread becomes
/// unresponsive (a "freeze") and records a diagnostic so the user has
/// some evidence after the fact.
///
/// ## How it works
///
/// A `DispatchSourceTimer` on a private background queue fires every
/// `pingInterval` seconds. On each tick it stamps the current time
/// and then asynchronously dispatches a small block back to the main
/// queue that updates a "main thread heartbeat" timestamp.
///
/// If the background queue ever notices that the heartbeat is stale
/// by more than `warnThreshold`, we log a warning. If it goes past
/// `freezeThreshold`, we treat that as a real freeze: log it, persist
/// a "last freeze" timestamp via `CrashRecoveryService`, and force a
/// snapshot of the recovery sentinel so even a forced kill at this
/// point won't lose the active preset.
///
/// ## Threading
///
/// **Not** `@MainActor`. The watchdog's whole job is to run on a
/// background queue. `@Published` mutations are dispatched to main
/// so SwiftUI observers stay happy. Internal counters are protected
/// by the private dispatch queue used as a serial lock.
///
/// The watchdog never tries to kill the app itself. macOS already has
/// its own spinning-beachball UI and force-quit affordances; we just
/// observe and persist.
final class FreezeWatchdogService: ObservableObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = FreezeWatchdogService()

    /// Toggle exposed in Settings → General → Reliability. Always mutated
    /// on the main thread. Toggling here cascades to `start()` / `stop()`.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledPrefKey)
            if enabled { start() } else { stop() }
        }
    }

    private static let enabledPrefKey = "JoystickConfig.freezeWatchdog.enabled"

    /// Background queue runs the timer that does the actual heartbeat
    /// checks. Kept at utility QoS so it never competes with input
    /// processing or UI work. Also doubles as a serial-lock for the
    /// internal counters below.
    private let queue = DispatchQueue(label: "JoystickConfig.FreezeWatchdog",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Last time the main thread checked in. Read and written only from
    /// `queue`, so no explicit lock needed.
    private var lastHeartbeat: TimeInterval = Date().timeIntervalSince1970
    private var lastReportedFreeze: TimeInterval = 0

    /// How often the watchdog pings.
    private let pingInterval: TimeInterval = 1.0
    /// Stale-heartbeat threshold that triggers a warning log entry.
    private let warnThreshold: TimeInterval = 5.0
    /// Stale-heartbeat threshold that we report as a real freeze.
    private let freezeThreshold: TimeInterval = 15.0
    /// Don't spam: only one freeze report per this many seconds.
    private let freezeCooldown: TimeInterval = 60.0

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledPrefKey) == nil {
            defaults.set(true, forKey: Self.enabledPrefKey)
        }
        enabled = defaults.bool(forKey: Self.enabledPrefKey)
        if enabled { start() }
    }

    // MARK: - Lifecycle

    func start() {
        // Always mutate `timer` and `lastHeartbeat` on `queue` so all
        // accesses are serialized through a single dispatch queue.
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.timer == nil else { return }
            self.lastHeartbeat = Date().timeIntervalSince1970

            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.pingInterval,
                       repeating: self.pingInterval)
            t.setEventHandler { [weak self] in
                self?.tick()
            }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // MARK: - Watchdog logic

    /// Called every `pingInterval` on the background queue. Checks how
    /// stale the main-thread heartbeat is and reacts accordingly, then
    /// schedules a fresh heartbeat ping back on the main thread.
    private func tick() {
        // Already on `queue` because the DispatchSource was created with
        // queue=queue, so direct access is safe here.
        let now = Date().timeIntervalSince1970
        let stallSeconds = now - lastHeartbeat

        if stallSeconds >= freezeThreshold,
           (now - lastReportedFreeze) > freezeCooldown {
            // Real freeze. Persist via the recovery service (which is
            // @MainActor) so we don't lose state if the user force-quits
            // from here, and log to Console.
            lastReportedFreeze = now
            let seconds = Int(stallSeconds)
            NSLog("FreezeWatchdog: main thread stalled \(seconds)s")
            DispatchQueue.main.async {
                CrashRecoveryService.shared.recordFreezeDetected()
            }
        } else if stallSeconds >= warnThreshold {
            NSLog("FreezeWatchdog: main thread slow (\(Int(stallSeconds))s)")
        }

        // Schedule a fresh heartbeat from the main thread. If main is
        // actually frozen this block will queue up but never run until
        // the freeze ends - exactly the signal we want.
        DispatchQueue.main.async { [weak self] in
            let stamp = Date().timeIntervalSince1970
            self?.queue.async {
                self?.lastHeartbeat = stamp
            }
        }
    }
}
