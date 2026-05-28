import Foundation
import AppKit

/// Tracks session lifecycle so the app can restore the user's previous
/// active preset after a crash or unexpected exit, while protecting
/// against restart loops if something keeps crashing.
///
/// ## How it works
///
/// On every launch we write a small JSON "sentinel" to disk capturing
/// the current session: session UUID, process ID, active preset ID,
/// and a `cleanShutdown` flag (initially `false`). When the user quits
/// normally via Cmd+Q the app delegate flips `cleanShutdown` to `true`
/// before exit.
///
/// On the next launch we read the previous sentinel:
///
/// * `cleanShutdown == true`  → previous session ended normally, skip.
/// * `cleanShutdown == false` → previous session crashed or was killed.
///   If we haven't already attempted a recovery within the last
///   `recoveryLoopWindow` seconds, restore the previous active preset.
///   Otherwise we suppress recovery to avoid an infinite crash-restore
///   loop.
///
/// ## Force-quit vs. crash
///
/// A force quit (Activity Monitor → kill, or `kill -9`) leaves the
/// sentinel in the same "not clean" state as a crash, because the
/// process is killed before it can flip the flag. From inside the
/// process we cannot reliably distinguish the two. The behaviour is
/// the same in both cases: the user gets their preset back. If they
/// want to suppress that they can disable session restore in
/// Settings → General → Reliability.
@MainActor
final class CrashRecoveryService: ObservableObject {
    static let shared = CrashRecoveryService()

    /// True if the previous session ended abnormally and we are about
    /// to restore (or have just restored) its active preset. The view
    /// layer can surface a one-shot banner explaining what happened.
    @Published private(set) var didRecoverPreviousSession = false

    /// Product-facing toggle: when false, even after a crash we leave
    /// the user on a blank state. Persisted via `UserDefaults` so the
    /// preference survives across launches. Default: enabled.
    @Published var sessionRestoreEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sessionRestoreEnabled,
                                      forKey: Self.sessionRestorePrefKey)
        }
    }

    /// Last time we recorded a freeze diagnostic from the watchdog.
    /// Surfaced in Settings for visibility.
    @Published private(set) var lastFreezeAt: Date?

    /// Preset ID we should restore on this launch, if any. Cleared
    /// after the caller consumes it.
    private(set) var presetIDToRestore: UUID?

    private let fileURL: URL
    private static let sessionRestorePrefKey = "JoystickConfig.sessionRestore.enabled"
    private static let lastFreezeKey = "JoystickConfig.recovery.lastFreezeAt"

    /// Window during which a second crash will NOT trigger another
    /// auto-restore. 90 seconds is long enough to weed out the case
    /// where the restored state itself is causing the crash, while
    /// still being short enough that an unrelated later crash doesn't
    /// suppress recovery.
    private let recoveryLoopWindow: TimeInterval = 90

    /// In-memory snapshot of the current session that we write to disk
    /// on every change. Always represents the current process.
    private var currentSession: Session

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("JoystickConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("recovery.json")

        let defaults = UserDefaults.standard
        // Default to enabled; only disable if the user explicitly turned it off.
        if defaults.object(forKey: Self.sessionRestorePrefKey) == nil {
            defaults.set(true, forKey: Self.sessionRestorePrefKey)
        }
        sessionRestoreEnabled = defaults.bool(forKey: Self.sessionRestorePrefKey)

        if let ts = defaults.object(forKey: Self.lastFreezeKey) as? TimeInterval {
            lastFreezeAt = Date(timeIntervalSince1970: ts)
        }

        // Start a brand-new session record for this launch. We mutate
        // this in-place as the user activates presets and finally on
        // clean shutdown.
        currentSession = Session(sessionID: UUID(),
                                 sessionStart: Date().timeIntervalSince1970,
                                 processID: Int(ProcessInfo.processInfo.processIdentifier),
                                 activePresetID: nil,
                                 cleanShutdown: false,
                                 lastRecoveryAttempt: nil)

        // Read the previous session BEFORE we overwrite the file. This
        // tells us whether the last process exited cleanly.
        let previous = readSentinel()
        determineRecoveryDecision(from: previous)
        writeSentinel()

        // Catch normal terminations so we can flip cleanShutdown=true.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleWillTerminate),
                                               name: NSApplication.willTerminateNotification,
                                               object: nil)
    }

    // MARK: - Public API

    /// Call whenever the user activates a different preset so the
    /// recovery file always reflects the latest "wanted" state.
    func recordActivePreset(_ presetID: UUID?) {
        currentSession.activePresetID = presetID
        writeSentinel()
    }

    /// Consume the pending restore target. Returns the preset ID that
    /// should be re-activated, then clears the in-memory marker so the
    /// caller can't accidentally re-trigger it. Safe to call exactly
    /// once at app startup; subsequent calls return nil.
    func consumeRestoreTarget() -> UUID? {
        guard let id = presetIDToRestore else { return nil }
        presetIDToRestore = nil
        return id
    }

    /// Called by `FreezeWatchdogService` when a hang is observed. We
    /// record the timestamp so the user can see "Last freeze detected"
    /// in Settings, and we force-write the recovery file so a
    /// subsequent hard kill doesn't lose freshly-activated presets.
    func recordFreezeDetected() {
        let now = Date()
        lastFreezeAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastFreezeKey)
        writeSentinel()
    }

    // MARK: - Internal

    private func determineRecoveryDecision(from previous: Session?) {
        guard sessionRestoreEnabled,
              let prev = previous,
              prev.cleanShutdown == false,
              let presetID = prev.activePresetID else {
            return
        }

        // Loop protection: if we already tried to recover from a crash
        // very recently and ended up here AGAIN, the restored state is
        // probably the cause. Bail out for this launch so the user can
        // start clean and we don't ping-pong.
        if let lastAttempt = prev.lastRecoveryAttempt {
            let elapsed = Date().timeIntervalSince1970 - lastAttempt
            if elapsed < recoveryLoopWindow {
                NSLog("CrashRecoveryService: suppressing recovery (loop within \(Int(elapsed))s)")
                return
            }
        }

        presetIDToRestore = presetID
        didRecoverPreviousSession = true
        currentSession.lastRecoveryAttempt = Date().timeIntervalSince1970
    }

    @objc private func handleWillTerminate() {
        currentSession.cleanShutdown = true
        writeSentinel()
    }

    private func readSentinel() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private func writeSentinel() {
        guard let data = try? JSONEncoder().encode(currentSession) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Codable session record

    /// Persisted shape of the recovery sentinel.
    private struct Session: Codable {
        var sessionID: UUID
        var sessionStart: TimeInterval
        var processID: Int
        var activePresetID: UUID?
        var cleanShutdown: Bool
        /// Timestamp of the *previous* launch's recovery attempt. Used
        /// to detect crash loops across two consecutive launches.
        var lastRecoveryAttempt: TimeInterval?
    }
}
