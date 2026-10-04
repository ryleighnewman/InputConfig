import Foundation
import AppKit
import Combine
import StoreKit
import Security

/// Decides when to ask for an App Store rating.
///
/// The ask is the system review sheet (StoreKit's `requestReview`) and
/// nothing else: a card of our own in front of it pre-screened who saw the
/// real one, and recorded "rated" even when the system chose not to show
/// its sheet. Apple limits how often that sheet may appear (three times a
/// year), so this service asks only people who have clearly been using the
/// app: several preset activations spread over a few days, and never twice
/// in four months. Someone who chose "Don't ask again" on the old card, or
/// rated from it, is not asked again.
@MainActor
final class ReviewPromptService: ObservableObject {

    static let shared = ReviewPromptService()

    /// Bumped when the system review sheet should be requested; the main
    /// window's presenter calls `requestReview` on each change.
    @Published private(set) var reviewRequest = 0

    static let activationsKey = "InputConfig.review.activations"
    static let firstLaunchKey = "InputConfig.review.firstLaunch"
    static let lastAskedKey = "InputConfig.review.lastAsked"
    static let stateKey = "InputConfig.review.state"   // "", "rated", "never"
    /// Keys that survive Reset Settings, so a reset does not re-ask.
    static let persistentKeys = [activationsKey, firstLaunchKey, lastAskedKey, stateKey, launchesKey]

    static let launchesKey = "InputConfig.review.launches"

    /// How much use counts as "has clearly been using it": eight
    /// activations, over at least three days and three separate launches,
    /// and never in the first ten minutes of a launch. The last two are
    /// what keep the card from landing on someone who just opened the app
    /// for the third time and activated the first thing they saw.
    static let activationsNeeded = 8
    static let daysNeeded = 3
    static let launchesNeeded = 3
    static let minutesIntoLaunchNeeded = 10.0
    static let daysBetweenAsks = 120

    private var askedThisLaunch = false
    private let launchedAt = Date()
    private let defaults = UserDefaults.standard

    private init() {
        if defaults.object(forKey: Self.firstLaunchKey) == nil {
            defaults.set(Date(), forKey: Self.firstLaunchKey)
        }
        defaults.set(defaults.integer(forKey: Self.launchesKey) + 1, forKey: Self.launchesKey)
    }

    /// Called whenever a preset starts running. The ask, when due, waits a
    /// beat so it never lands on top of the activation itself.
    func recordActivation() {
        let n = defaults.integer(forKey: Self.activationsKey) + 1
        defaults.set(n, forKey: Self.activationsKey)
        guard isDue else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.offerIfQuiet()
        }
    }

    var isDue: Bool {
        if askedThisLaunch { return false }
        let state = defaults.string(forKey: Self.stateKey) ?? ""
        if state == "never" || state == "rated" { return false }
        guard defaults.integer(forKey: Self.activationsKey) >= Self.activationsNeeded else { return false }
        let first = defaults.object(forKey: Self.firstLaunchKey) as? Date ?? Date()
        guard Date().timeIntervalSince(first) >= Double(Self.daysNeeded) * 86_400 else { return false }
        guard defaults.integer(forKey: Self.launchesKey) >= Self.launchesNeeded else { return false }
        guard Date().timeIntervalSince(launchedAt) >= Self.minutesIntoLaunchNeeded * 60 else { return false }
        if let last = defaults.object(forKey: Self.lastAskedKey) as? Date,
           Date().timeIntervalSince(last) < Double(Self.daysBetweenAsks) * 86_400 {
            return false
        }
        return true
    }

    /// Ask only when the app is in front with its window up and nothing
    /// else (an editor, a tour) is in the way.
    private func offerIfQuiet() {
        // The main window, not Help or the Tip Jar: only the main window
        // can show the ask, and an ask nobody saw still blocked the next
        // one for four months.
        guard isDue, NSApp.isActive,
              let window = NSApp.keyWindow, window === MenuBarController.mainWindow,
              window.attachedSheet == nil, window.isVisible, !window.isMiniaturized else { return }
        present()
    }

    /// Request the system review sheet now (also the debug hook's entry
    /// point). Only a Mac App Store copy can show it; the Homebrew copy has
    /// the Rate InputConfig menu item instead.
    func present() {
        askedThisLaunch = true
        defaults.set(Date(), forKey: Self.lastAskedKey)
        if Self.isAppStoreCopy { reviewRequest &+= 1 }
    }

    /// The App Store page, opened to the review form, for a manual
    /// "Rate InputConfig" menu item.
    static let writeReviewURL = URL(string: "https://apps.apple.com/us/app/inputconfig/id6777759147?action=write-review")!

    /// True for a copy installed from the Mac App Store, which carries a
    /// receipt. The Homebrew copy (Developer ID) has none, and there the
    /// system review sheet does nothing, so a yes opens the review page.
    static var isAppStoreCopy: Bool { AppStoreCopy.isAppStoreCopy }
}

/// Whether this copy came from the Mac App Store. The receipt file can be
/// missing on a fresh install or under App Review, so the code signature is
/// checked too. StoreKit is not asked at launch: fetching an app transaction
/// can put an Apple Account sign-in in front of an app that has no accounts.
enum AppStoreCopy {
    static var isAppStoreCopy: Bool {
        if signedByAppStore { return true }
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static let signedByAppStore: Bool = signedForAppStore()

    /// True when this copy is signed with Apple's App Store certificate,
    /// which carries the Mac App Store signing extension (6.1.9), or the
    /// TestFlight one (6.1.9.1).
    private static func signedForAppStore() -> Bool {
        satisfies("anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate leaf[field.1.2.840.113635.100.6.1.9.1] exists)")
    }

    /// True for a Developer ID copy (the Homebrew build): the only kind that
    /// is certainly not from the App Store, so the only one told so.
    static let isDeveloperIDCopy: Bool = satisfies(
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")

    private static func satisfies(_ requirementText: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
