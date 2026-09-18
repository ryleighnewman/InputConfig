import Foundation
import AppKit
import Combine

/// Decides when to ask for an App Store rating, and remembers the answer.
///
/// The ask itself is the system review sheet (StoreKit's `requestReview`),
/// which is the only way a person can tap a star right there and the only
/// way Apple allows a rating to be collected in-app. Apple also limits how
/// often that sheet may appear (three times a year, and never on demand
/// while the app is being reviewed), so this service asks only people who
/// have clearly been using the app: several preset activations spread over
/// a few days, and never twice in four months. "Don't ask again" is final.
@MainActor
final class ReviewPromptService: ObservableObject {

    static let shared = ReviewPromptService()

    /// True while the in-app "would you rate it?" card should be up.
    @Published var showPrompt = false
    /// True for a moment after a rating was offered, for the thank-you.
    @Published var celebrate = false

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

    /// Show the card only when the app is in front with its window up and
    /// nothing else (an editor, a tour) is in the way.
    private func offerIfQuiet() {
        guard isDue, NSApp.isActive,
              let window = NSApp.keyWindow, window.attachedSheet == nil,
              window.isVisible, !window.isMiniaturized else { return }
        present()
    }

    /// Put the card up now (also the debug hook's entry point).
    func present() {
        askedThisLaunch = true
        defaults.set(Date(), forKey: Self.lastAskedKey)
        showPrompt = true
    }

    // MARK: - Answers

    /// They said yes: the caller shows the system sheet; we remember and
    /// start the thank-you.
    func accepted() {
        defaults.set("rated", forKey: Self.stateKey)
        showPrompt = false
        celebrate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            self?.celebrate = false
        }
    }

    /// "Not now": ask again after the usual gap.
    func snoozed() {
        showPrompt = false
    }

    /// "Don't ask again": final.
    func declined() {
        defaults.set("never", forKey: Self.stateKey)
        showPrompt = false
    }

    /// The App Store page, opened to the review form, for a manual
    /// "Rate InputConfig" menu item.
    static let writeReviewURL = URL(string: "https://apps.apple.com/us/app/inputconfig/id6777759147?action=write-review")!
}
