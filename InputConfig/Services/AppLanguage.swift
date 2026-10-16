import AppKit

/// The languages InputConfig is translated into, the same set as
/// inputconfig.com, and the app's own choice among them. "Same as the
/// system" follows the order in System Settings, General, Language and
/// Region (where a per-app language can be set too); picking one here stores
/// it for InputConfig alone, which macOS applies at the next launch.
enum AppLanguage {
    /// Localization identifiers, English first, then by code.
    static let codes = ["en", "ar", "cs", "da", "de", "es", "fi", "fr", "he", "hu", "id", "it", "ja", "ko",
                        "nb", "nl", "pl", "pt-BR", "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

    private static let key = "AppleLanguages"

    /// A language's name in that language ("Deutsch", "日本語").
    static func nativeName(_ code: String) -> String {
        let l = Locale(identifier: code)
        let name = l.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: l) + name.dropFirst()
    }

    /// The language picked for InputConfig, or nil when it follows the system.
    /// Read from the app's own domain only, so the system list never counts
    /// as a choice.
    static var chosen: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first else { return nil }
        if codes.contains(first) { return first }
        // A value with a region ("de-DE", as System Settings may store it)
        // is the language the app shows for it, when the app has one.
        let base = Locale(identifier: first).language.languageCode?.identifier
        guard let match = Bundle.preferredLocalizations(from: codes, forPreferences: [first]).first,
              match != "en" || base == "en" else { return nil }
        return match
    }

    /// The language the app is showing now.
    static var current: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The language the next launch will show: the choice, or the first
    /// of the system's languages the app has (zh-Hant-TW is zh-Hant, a
    /// language the app lacks falls through to the next one).
    static var nextLaunch: String {
        let prefs = chosen.map { [$0] } ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: codes, forPreferences: prefs).first ?? "en"
    }

    /// Stores the choice for the next launch (nil follows the system).
    static func choose(_ code: String?) {
        if let code { UserDefaults.standard.set([code], forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Set while a language change is restarting the app; the copy that
    /// replaces this one starts as this one finishes quitting.
    @MainActor static var relaunchPending = false

    /// Quits through the normal path (an open editor is saved or discarded
    /// first, and Cancel there cancels the restart) and starts a new copy as
    /// the quit completes, so the language takes effect.
    @MainActor
    static func relaunch() {
        relaunchPending = true
        // The running preset comes back in the new copy: someone who drives
        // the pointer with it could not reach Activate again.
        if let id = MenuBarController.shared.activePresetID {
            UserDefaults.standard.set(id.uuidString, forKey: relaunchPresetKey)
        } else {
            UserDefaults.standard.removeObject(forKey: relaunchPresetKey)
        }
        if let quit = QuitCoordinator.shared { quit.requestQuit() } else { NSApplication.shared.terminate(nil) }
    }

    /// From applicationWillTerminate: start the replacement, passing this
    /// copy's process ID so it waits for this one to be gone.
    @MainActor
    static func launchReplacement() {
        guard relaunchPending else { return }
        relaunchPending = false
        // Which copy the new one waits for, through the app's defaults:
        // macOS drops the launch arguments a sandboxed app passes, so the
        // new copy found this one still quitting and said a copy was
        // already running.
        UserDefaults.standard.set([Double(ProcessInfo.processInfo.processIdentifier), Date().timeIntervalSince1970],
                                  forKey: relaunchFromKey)
        UserDefaults.standard.synchronize()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        config.arguments = [relaunchArgument, String(ProcessInfo.processInfo.processIdentifier)]
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }

    /// Whether a process is still alive, asked of the kernel: the running
    /// applications list of a copy still starting up does not refresh until
    /// its run loop runs, so it keeps listing a copy that has quit.
    static func isAlive(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return true }
        return size > 0
    }

    /// Passed, with the old copy's process ID, to the copy a restart starts.
    static let relaunchArgument = "--relaunch-for-language"
    /// The quitting copy's process ID and when it asked, for the copy a
    /// restart starts (see launchReplacement).
    static let relaunchFromKey = "InputConfig.relaunchFrom"
    /// This copy was started by Restart Now (told by its arguments or by
    /// the defaults mark), so it brings back the preset that was running.
    nonisolated(unsafe) static var startedByRestart = false
    /// The preset that was running when Restart Now was pressed.
    static let relaunchPresetKey = "InputConfig.relaunchPreset"
}

/// Lists in the app's language: "A, B and C", "A or B".
enum LocalizedList {
    static func and(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }

    static func or(_ items: [String]) -> String {
        // Chained pair by pair: ListFormatter only joins with "and".
        guard let first = items.first else { return "" }
        return items.dropFirst().reduce(first) { String(localized: "\($0) or \($1)") }
    }
}
