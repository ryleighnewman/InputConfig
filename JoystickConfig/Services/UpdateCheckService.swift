import Foundation
import AppKit

/// Polls Apple's iTunes Lookup API to find out whether a newer version of
/// JoystickConfig has been released on the Mac App Store, and (when one has)
/// surfaces an `@Published` flag the rest of the app can observe to show
/// a "Update available" alert with a deep link into the App Store.
///
/// ## How the check works
///
/// We hit `https://itunes.apple.com/lookup?id=<appID>&entity=macSoftware`
/// which returns one result containing the latest version string Apple has
/// promoted for that app record. We compare it against this binary's
/// `CFBundleShortVersionString` using a tuple-of-integers semantic-version
/// comparison so "1.10" correctly beats "1.9".
///
/// ## Throttling
///
/// We only hit the network once per `minCheckInterval` (default 24h) so
/// users on metered connections don't get hammered. The last-checked
/// timestamp is persisted across launches.
///
/// ## Privacy
///
/// The lookup endpoint is anonymous - no Apple ID, no IDFA, no app
/// usage data. Just a numeric app store ID in the URL. The Settings UI
/// surfaces a toggle to turn the check off completely.
@MainActor
final class UpdateCheckService: ObservableObject {
    static let shared = UpdateCheckService()

    /// The numeric App Store ID for this app's product record. Pinned
    /// here so we never hit the wrong app's listing. Matches the value
    /// in the App Store URL: apps.apple.com/.../id6761875440.
    static let appStoreID = "6761875440"

    /// Public-facing App Store URL the user is sent to when they click
    /// "Open App Store" on the update prompt. Uses the macappstore://
    /// scheme so the Mac App Store app opens directly (vs. Safari first).
    static let appStoreURL = URL(string:
        "macappstore://apps.apple.com/app/id\(appStoreID)?mt=12")!

    /// Fallback HTTPS URL in case the macappstore:// scheme is unavailable.
    static let appStoreFallbackURL = URL(string:
        "https://apps.apple.com/app/id\(appStoreID)?mt=12")!

    // MARK: - Published state

    /// Non-nil while we know a newer version is available. The string is
    /// the App Store version (e.g. "1.2").
    @Published private(set) var availableUpdateVersion: String?

    /// User preference: when false, no automatic checks fire and the
    /// alert never appears. Manual "Check Now" still works from Settings.
    @Published var automaticCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticCheckEnabled,
                                      forKey: Self.autoCheckPrefKey)
        }
    }

    /// When we last hit the network. Surfaced in Settings.
    @Published private(set) var lastCheckedAt: Date?

    /// True while an active HTTP request is in flight.
    @Published private(set) var isChecking = false

    /// Latest error from a failed network check, for user-visible display.
    @Published private(set) var lastErrorMessage: String?

    // MARK: - Constants

    private static let autoCheckPrefKey = "JoystickConfig.updateCheck.enabled"
    private static let lastCheckedAtKey = "JoystickConfig.updateCheck.lastCheckedAt"
    /// Which versions the user already dismissed an alert for. We won't
    /// re-prompt for the same version on subsequent launches.
    private static let dismissedVersionsKey = "JoystickConfig.updateCheck.dismissedVersions"

    /// Minimum seconds between automatic checks. 24 hours.
    private let minCheckInterval: TimeInterval = 86_400

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.autoCheckPrefKey) == nil {
            defaults.set(true, forKey: Self.autoCheckPrefKey)
        }
        automaticCheckEnabled = defaults.bool(forKey: Self.autoCheckPrefKey)
        if let ts = defaults.object(forKey: Self.lastCheckedAtKey) as? TimeInterval {
            lastCheckedAt = Date(timeIntervalSince1970: ts)
        }
    }

    // MARK: - Public API

    /// Boot the service: if automatic checks are on AND we haven't checked
    /// recently AND the user hasn't already dismissed an alert for the
    /// currently-released version, fire one off in the background.
    /// Called from `AppState.init` so it runs at app launch.
    func runAutomaticCheckIfNeeded() {
        guard automaticCheckEnabled else { return }
        if let last = lastCheckedAt,
           Date().timeIntervalSince(last) < minCheckInterval {
            return
        }
        Task { await checkNow(userInitiated: false) }
    }

    /// User-initiated "Check Now" button from Settings. Always runs,
    /// regardless of throttling.
    @discardableResult
    func checkNow(userInitiated: Bool = true) async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        lastErrorMessage = nil
        defer { isChecking = false }

        do {
            let latest = try await fetchLatestVersionFromAppStore()
            let now = Date()
            lastCheckedAt = now
            UserDefaults.standard.set(now.timeIntervalSince1970,
                                      forKey: Self.lastCheckedAtKey)

            let current = currentInstalledVersion
            if Self.compare(latest, isNewerThan: current) {
                // Suppress the alert if the user already dismissed THIS
                // version (manual checks ignore the suppression so the
                // user can re-prompt themselves).
                if !userInitiated && isDismissed(latest) {
                    availableUpdateVersion = nil
                    return false
                }
                availableUpdateVersion = latest
                return true
            } else {
                availableUpdateVersion = nil
                return false
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            NSLog("UpdateCheckService: \(error.localizedDescription)")
            return false
        }
    }

    /// Open the Mac App Store at this app's product page so the user can
    /// hit Update. Tries the macappstore:// scheme first; falls back to
    /// the HTTPS URL if the scheme isn't available.
    func openAppStoreForUpdate() {
        if !NSWorkspace.shared.open(Self.appStoreURL) {
            NSWorkspace.shared.open(Self.appStoreFallbackURL)
        }
    }

    /// Called by the alert's "Not now" button. Suppresses the prompt for
    /// this specific version so we don't nag on every launch.
    func dismissAvailableUpdate() {
        if let v = availableUpdateVersion {
            markDismissed(v)
        }
        availableUpdateVersion = nil
    }

    // MARK: - Networking

    /// Hits the public iTunes lookup endpoint. Returns the latest version
    /// Apple has promoted for this app record.
    private func fetchLatestVersionFromAppStore() async throws -> String {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: Self.appStoreID),
            URLQueryItem(name: "entity", value: "macSoftware"),
            // Bust intermediate caches so we get fresh data.
            URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970)))
        ]
        guard let url = components.url else { throw UpdateError.malformedURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badStatusCode(
                (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let version = first["version"] as? String else {
            throw UpdateError.unexpectedPayload
        }
        return version
    }

    // MARK: - Version comparison

    /// Returns true iff `latest` is strictly newer than `current` using
    /// component-wise integer comparison ("1.10" > "1.9").
    static func compare(_ latest: String, isNewerThan current: String) -> Bool {
        let l = latest.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        let maxLen = max(l.count, c.count)
        for i in 0..<maxLen {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }

    private var currentInstalledVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Per-version dismissal

    private func dismissedVersions() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.dismissedVersionsKey) ?? []
    }

    private func isDismissed(_ version: String) -> Bool {
        dismissedVersions().contains(version)
    }

    private func markDismissed(_ version: String) {
        var list = dismissedVersions()
        if !list.contains(version) {
            list.append(version)
            UserDefaults.standard.set(list, forKey: Self.dismissedVersionsKey)
        }
    }
}

private enum UpdateError: LocalizedError {
    case malformedURL
    case badStatusCode(Int)
    case unexpectedPayload

    var errorDescription: String? {
        switch self {
        case .malformedURL:
            return "Could not build the App Store lookup URL."
        case .badStatusCode(let code):
            return "App Store lookup returned HTTP \(code)."
        case .unexpectedPayload:
            return "App Store lookup returned an unexpected response."
        }
    }
}
