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
    static let shared = FreezeWatchdogService()

    /// Toggle exposed in Settings → General → Reliability. Always mutated
    /// on the main thread. Toggling here cascades to `start()` / `stop()`.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledPrefKey)
            // The switch covers the diagnostics only: letting go of held
            // keys during a hang always runs, as What's New promises.
            let on = enabled
            queue.async { [weak self] in self?.reports = on }
        }
    }

    private static let enabledPrefKey = "InputConfig.freezeWatchdog.enabled"

    /// Match the stored setting after Reset or Restore changed it underneath.
    func reloadFromDefaults() {
        let stored = (UserDefaults.standard.object(forKey: Self.enabledPrefKey) as? Bool) ?? true
        if stored != enabled { enabled = stored }
    }

    /// Background queue runs the timer that does the actual heartbeat
    /// checks. Kept at utility QoS so it never competes with input
    /// processing or UI work. Also doubles as a serial-lock for the
    /// internal counters below.
    private let queue = DispatchQueue(label: "InputConfig.FreezeWatchdog",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Last time the main thread checked in. Read and written only from
    /// `queue`, so no explicit lock needed.
    private var lastHeartbeat: TimeInterval = FreezeWatchdogService.uptime()
    private var lastReportedFreeze: TimeInterval = 0
    private var lastTick: TimeInterval = 0

    /// Seconds on a clock that stops while the Mac sleeps, so a nap is not
    /// read as a frozen main thread. Wall time jumped by the whole sleep, and
    /// a 15 to 90 s nap was reported as a freeze.
    static func uptime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

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
        reports = enabled
        start()
    }

    /// The Reliability switch, read on `queue`: whether a freeze is saved
    /// and logged. The release never depends on it.
    private var reports = true

    // MARK: - Lifecycle

    func start() {
        // Always mutate `timer` and `lastHeartbeat` on `queue` so all
        // accesses are serialized through a single dispatch queue.
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.timer == nil else { return }
            self.lastHeartbeat = Self.uptime()

            let t = DispatchSource.makeTimerSource(queue: self.queue)
            // Leeway lets the system batch this wake with others.
            t.schedule(deadline: .now() + self.pingInterval,
                       repeating: self.pingInterval, leeway: .milliseconds(250))
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

    /// From the watchdog's queue while main is hung. Every release path
    /// needs main, so whatever a preset holds (a key, a mouse button, a
    /// stick still steering the pointer) stays down for the whole hang. Let
    /// go from here, first: the pump is lock protected and the sweep
    /// releases only what this app posted down itself (its own lock-guarded
    /// record), never a key the person is holding through the hang. The
    /// engine's own bookkeeping is squared up on main once it answers again.
    /// Then the freeze is stamped durably, so a hard kill during the freeze
    /// does not lose the record. After the release: a defaults write waits
    /// on main whenever an observer of it is registered on the main queue.
    nonisolated static func letGoDuringFreeze() {
        MouseMotionPump.shared.stop()
        InputSimulator.shared.releaseOwnPostedLeftovers()
        InputSimulator.shared.forgetHeldPointerState()
        CrashRecoveryService.stampFreezeFromWatchdog()
    }

    /// Called every `pingInterval` on the background queue. Checks how
    /// stale the main-thread heartbeat is and reacts accordingly, then
    /// schedules a fresh heartbeat ping back on the main thread.
    private func tick() {
        // Already on `queue` because the DispatchSource was created with
        // queue=queue, so direct access is safe here.
        let now = Self.uptime()
        let stallSeconds = now - lastHeartbeat
        // This tick itself came late (App Nap, a busy system): the gap says
        // nothing about the main thread. Start the measure again, but only
        // when the late tick accounts for the whole stall: a heartbeat
        // already stale before the previous tick is a hang the late tick
        // must not erase.
        defer { lastTick = now }
        if lastTick > 0, now - lastTick > pingInterval * 3,
           stallSeconds <= (now - lastTick) + pingInterval {
            lastHeartbeat = now
            return
        }

        // A stall far longer than any UI freeze worth reporting is almost
        // certainly the machine having been asleep (or the process suspended),
        // not a hang. Reset the heartbeat instead of logging a bogus freeze on
        // every wake from sleep.
        if stallSeconds > 90 {
            lastHeartbeat = now
            return
        }

        // Every hang lets go once, however soon after the last one: riding
        // the report's 60 s cooldown, a second hang held its keys about 51 s.
        if stallSeconds >= freezeThreshold, !releasedDuringFreeze {
            Self.letGoDuringFreeze()
            releasedDuringFreeze = true
        }
        if stallSeconds >= freezeThreshold, reports,
           (now - lastReportedFreeze) > freezeCooldown {
            // Real freeze. Persist via the recovery service (which is
            // @MainActor) so we don't lose state if the user force-quits
            // from here, and log to Console.
            lastReportedFreeze = now
            let seconds = Int(stallSeconds)
            NSLog("FreezeWatchdog: main thread stalled \(seconds)s")
            ActivityLog.shared.warning("Watchdog", "Main thread stalled \(seconds)s; let go of every held key and button")
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
            guard let self else { return }
            let stamp = Self.uptime()
            self.queue.async {
                self.lastHeartbeat = stamp
                if self.releasedDuringFreeze {
                    self.releasedDuringFreeze = false
                    DispatchQueue.main.async { MainActor.assumeIsolated { Self.recoverAfterFreeze() } }
                }
            }
        }
    }

    /// Set on `queue` when the watchdog let go of held output during a
    /// freeze; cleared by the first heartbeat after it.
    private var releasedDuringFreeze = false

    /// Main is back: the normal release squares the engine's held sets with
    /// what the watchdog already let go of, and a running preset gets its
    /// pointer pump back (it sleeps on its own when nothing moves).
    @MainActor
    private static func recoverAfterFreeze() {
        InputSimulator.shared.releaseAll()
        // The engine's toggle latches, turbo and in-flight chains were made
        // with keys the watchdog already let go of; the engine squares them
        // up on this, the way its pause edge does, so a toggled row does not
        // stay logically on with its key up.
        NotificationCenter.default.post(name: InputSimulator.outputsForcedReleaseNotification,
                                        object: nil, userInfo: ["reason": "freeze"])
        if MappingEngine.current?.isRunning == true {
            MouseMotionPump.shared.start()
        }
    }
}
