import Foundation
import AVFoundation
import AppKit
import GameController
import CoreHaptics
import QuartzCore

/// Centralized service for non-input feedback when a binding fires:
/// haptic rumble on the controller and spoken phrases through the Mac or
/// controller speaker.
@MainActor
final class FeedbackService {
    static let shared = FeedbackService()

    private let speech = AVSpeechSynthesizer()
    private var hapticEngines: [ObjectIdentifier: CHHapticEngine] = [:]
    /// Patterns still playing. Held so a player is never released mid-buzz.
    private var activePlayers: [UUID: CHHapticPatternPlayer] = [:]
    /// Hears both synthesizers start and finish, for `speakingUntil`.
    private let speechWatcher = SpeechWatcher()

    /// Until when (CACurrentMediaTime) the app's own voice may still be
    /// heard by the microphone: the end of the current utterance plus a
    /// margin for the room. VoicePhraseService drops phrase matches from
    /// that stretch, so a spoken "jump" does not press jump again.
    static var speakingUntil: TimeInterval = 0
    /// The phrase spoken last, normalized the way VoicePhraseService
    /// normalizes what it hears, so only that phrase is dropped as an echo.
    @MainActor static var lastSpokenNormalized: String?
    /// The phrases said in the open speaking window (see speakingUntil).
    @MainActor static var spokenInWindow: [String] = []
    /// How many phrases may wait behind the one being spoken.
    private static let pendingCap = 2

    /// Echo margin past the end of speech.
    private static let speakingTail: TimeInterval = 0.3
    /// Cover from a speak call until the synthesizer reports it started.
    private static let speakingLead: TimeInterval = 2
    /// The longest an utterance is assumed to run when a synthesizer gives
    /// no end notice; the finish callback shortens it.
    private static let speakingCap: TimeInterval = 120

    private init() {
        speech.delegate = speechWatcher
    }

    // MARK: - Haptics

    /// Below this the vibration is a single transient tap, which is what a
    /// button-press confirmation should feel like; at or above it a
    /// continuous event runs for the requested time.
    static let transientCutoffMs = 60
    static let defaultDurationMs = 0
    /// What "a tap" means to a rumble motor.
    /// The shortest buzz the Sony report path plays. A DualSense emulates
    /// rumble with its haptic actuators and takes most of 200 ms to reach
    /// the strength it was asked for, so a shorter pulse felt weak at 100%
    /// even though the motor bytes were at their maximum (measured on a
    /// DualSense Edge: 140 ms at 100% felt like far less than a 700 ms buzz
    /// at the same bytes).
    static let rumblePulseMs = 220
    static let maxDurationMs = 2000

    /// Play a haptic on the given controller, if it supports Core Haptics: a
    /// short transient tap by default, or a continuous rumble lasting
    /// `durationMs`. Silently no-ops on controllers without haptics.
    #if DEBUG
    /// Five ways to make a controller buzz, each announced by the light bar
    /// so the result can be reported by color instead of by counting:
    ///   red     Apple's haptics, this app still writing the light bar
    ///   green   Apple's haptics, this app's writes paused
    ///   blue    this app's own output report carrying the motor bytes
    ///   yellow  Apple's haptics, engine stopped right after (what quitting does)
    ///   purple  this app lets go of the controller, then Apple's haptics
    /// `post inputconfig.debug.buzz`
    func debugBuzzTest(controller: GCController) {
        let ms = 400
        let writer = InProcessLightWriter.shared
        func announce(_ name: String, _ r: UInt8, _ g: UInt8, _ b: UInt8, at t: Double,
                      _ body: @escaping @MainActor @Sendable () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                NSLog("[BUZZ] %@", name)
                writer.startHold(red: r, green: g, blue: b)
            }
            // The color goes up first and stays; the buzz follows half a
            // second later so there is no doubt which one it belongs to.
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.5) { MainActor.assumeIsolated(body) }
        }
        NSLog("[BUZZ] five attempts, each with its own light bar color")
        announce("1 red: haptics, our writes running", 255, 0, 0, at: 0.2) {
            self.vibrateViaHaptics(controller: controller, intensity: 1.0, durationMs: ms)
        }
        announce("2 green: haptics, our writes paused", 0, 255, 0, at: 2.2) {
            writer.pauseWrites(forMs: ms + 600)
            self.vibrateViaHaptics(controller: controller, intensity: 1.0, durationMs: ms)
        }
        announce("3 blue: our own output report", 0, 0, 255, at: 4.2) {
            writer.vibrate(intensity: 1.0, durationMs: ms,
                           target: SonyPadIdentity.of(controller: controller))
        }
        announce("4 yellow: haptics then engine stop", 255, 200, 0, at: 6.2) {
            self.vibrateViaHaptics(controller: controller, intensity: 1.0, durationMs: ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.clearHapticEngines() }
        }
        announce("5 purple: we let go of the pad, then haptics", 180, 0, 255, at: 8.2) {
            writer.closeForTest()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.vibrateViaHaptics(controller: controller, intensity: 1.0, durationMs: ms)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
            NSLog("[BUZZ] done")
            writer.stopHold()
        }
    }
    #endif

    /// The CHHaptics path on its own, so the test can call it directly.
    func vibrateViaHaptics(controller: GCController, intensity: Float, durationMs: Int) {
        vibrateUsingEngine(controller: controller, intensity: intensity, sharpness: 0.5, durationMs: durationMs)
    }

    /// Which path the last engine rumble took, for the debug dump.
    nonisolated(unsafe) static var debugLastPath: String = "none"

    func vibrate(controller: GCController, intensity: Float = 0.6, sharpness: Float = 0.5, durationMs: Int = 0) {
        #if DEBUG
        if TestCapture.blocksDevices { TestCapture.note("rumble \(intensity)"); return }
        #endif
        // Sony pads buzz through the report this app already writes for the
        // light bar. Asking the system to play the haptic hands it the
        // controller's report stream and it repaints the light bar for as
        // long as it holds it, which nothing this app writes can outrun: the
        // preset's color was replaced on every press that buzzed. Carrying
        // the motor values ourselves means one writer and one color.
        let name = ((controller.vendorName ?? "") + " " + controller.productCategory).lowercased()
        // The Access controller can report a DualSense name; it is no Sony
        // pad to the raw writer, which would buzz the real DualSense.
        let sony = (name.contains("dualsense") || name.contains("dualshock"))
            && ControllerTypeDetector.detect(controller) != .accessController
        if sony, InProcessLightWriter.shared.ownsAnyDualSense {
            // A duration of 0 means "a tap", but a motor needs time to spin
            // up, so a tap gets a short pulse rather than nothing felt.
            let ms = durationMs > 0 ? max(durationMs, Self.rumblePulseMs) : Self.rumblePulseMs
            Self.debugLastPath = "report intensity=\(intensity) ms=\(ms) name=\(name)"
            // Aim the buzz at this controller's own pad. With two Sony pads
            // connected the old call shook both; the writer falls back to
            // every pad only when it cannot tell which one this is.
            InProcessLightWriter.shared.vibrate(intensity: intensity, durationMs: ms,
                                                target: SonyPadIdentity.of(controller: controller))
            return
        }
        Self.debugLastPath = "apple intensity=\(intensity) ms=\(durationMs) sony=\(sony) name=\(name)"
        vibrateUsingEngine(controller: controller, intensity: intensity, sharpness: sharpness, durationMs: durationMs)
    }

    private func vibrateUsingEngine(controller: GCController, intensity: Float, sharpness: Float, durationMs: Int) {
        #if DEBUG
        if TestCapture.blocksDevices { TestCapture.note("rumble \(intensity)"); return }
        #endif
        guard let haptics = controller.haptics else { return }
        let key = ObjectIdentifier(controller)

        let engine: CHHapticEngine
        if let existing = hapticEngines[key] {
            engine = existing
        } else {
            guard let new = haptics.createEngine(withLocality: .default) else { return }
            do {
                try new.start()
            } catch {
                return
            }
            new.resetHandler = { [weak self, weak new] in
                guard let new = new else { return }
                try? new.start()
                _ = self
            }
            // A stopped engine (audio interruption, the system tearing it
            // down) is forgotten so the next buzz builds a fresh one,
            // instead of every later player.start throwing into silence
            // until the app is relaunched.
            new.stoppedHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.hapticEngines.removeValue(forKey: key) }
            }
            hapticEngines[key] = new
            engine = new
        }

        do {
            let params = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0, min(1, intensity))),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, sharpness))),
            ]
            let event: CHHapticEvent
            if durationMs >= Self.transientCutoffMs {
                let seconds = Double(min(Self.maxDurationMs, durationMs)) / 1000
                event = CHHapticEvent(eventType: .hapticContinuous, parameters: params,
                                      relativeTime: 0, duration: seconds)
            } else {
                event = CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: 0)
            }
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            // Keep the player alive until the pattern is done, then stop it.
            // Letting it go out of scope mid-pattern leaves the controller's
            // haptic stream running with nobody left holding it: that is how
            // a pad ends up buzzing with no app in sight.
            let token = UUID()
            activePlayers[token] = player
            let holdFor = Double(min(Self.maxDurationMs, max(durationMs, Self.transientCutoffMs))) / 1000 + 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + holdFor) { [weak self] in
                guard let self = self, let p = self.activePlayers.removeValue(forKey: token) else { return }
                try? p.stop(atTime: CHHapticTimeImmediate)
            }
        } catch {
            // Best effort; ignore failures
        }
    }

    /// Drop one controller's engine when it disconnects.
    func forgetController(id key: ObjectIdentifier) {
        if let engine = hapticEngines.removeValue(forKey: key) {
            engine.stop(completionHandler: nil)
        }
    }

    /// Tear down haptic engines (called when controllers disconnect or app quits).
    func clearHapticEngines() {
        for p in activePlayers.values { try? p.stop(atTime: CHHapticTimeImmediate) }
        activePlayers.removeAll()
        for engine in hapticEngines.values {
            engine.stop(completionHandler: nil)
        }
        hapticEngines.removeAll()
    }

    // MARK: - Speech

    /// Speak a phrase. The destination decides which audio device to use.
    /// "Mac" plays through whatever audio output the Mac is currently using.
    /// "Controller" routes audio through the controller speaker when one is
    /// connected as an audio output device, otherwise falls back to Mac.
    /// UserDefaults key for the chosen voice identifier. Empty means the
    /// Mac's System Voice from Accessibility, Spoken Content.
    static let voiceKey = "InputConfig.speechVoice"

    /// Speaks with the System Voice; see SystemVoice at the end of this
    /// file for why it is the deprecated synthesizer.
    private lazy var systemSpeech: any SystemVoiceSpeaking = SystemVoice()
    /// System Voice phrases waiting their turn: NSSpeechSynthesizer cuts
    /// the phrase under way when asked to start another, where
    /// AVSpeechSynthesizer queues it.
    private var pendingSystemPhrases: [String] = []
    /// Phrases handed to AVSpeechSynthesizer that have not finished, the
    /// one being spoken included; it queues them itself.
    private var voiceUtterances: Set<ObjectIdentifier> = []
    private var voiceQueued: Int { voiceUtterances.count }
    /// The phrase being spoken right now. The same phrase again (a held
    /// button) starts over; a different one from another binding waits
    /// its turn.
    private var speakingPhrase: String?

    /// Every installed voice for the user's languages, premium first.
    static func installedVoices() -> [AVSpeechSynthesisVoice] {
        // The Mac's own languages as well as the app's: a language picked
        // for InputConfig alone narrows Locale.preferredLanguages to it, and
        // dropped every voice in the Mac's language.
        let system = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        let preferred = Set((system + Locale.preferredLanguages).map { String($0.prefix(2)) })
        let chosen = UserDefaults.standard.string(forKey: voiceKey) ?? ""
        let novelty = "com.apple.speech.synthesis.voice."
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { ($0.identifier == chosen || preferred.contains(String($0.language.prefix(2)))) && !$0.identifier.hasPrefix(novelty) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if a.language != b.language { return a.language < b.language }
                return a.name < b.name
            }
    }

    /// Speak a phrase. The destination decides which audio device to use.
    /// "Mac" plays through whatever audio output the Mac is currently using.
    /// "Controller" routes audio through the controller speaker when one is
    /// connected as an audio output device, otherwise falls back to Mac.
    /// `appText`: the phrase is the app's own words, in the app's language,
    /// so a System Voice in another language does not read it.
    func speak(_ phrase: String, destination: SpeechDestination = .mac, rate: Float = AVSpeechUtteranceDefaultSpeechRate,
               appText: Bool = false) {
        #if DEBUG
        if TestCapture.active { TestCapture.note("speak \(phrase)"); return }
        #endif
        guard !phrase.isEmpty else { return }
        // Note: on macOS there is no public API to pin speech to a specific output device.
        // The user can route audio to the controller speaker via System Settings > Sound,
        // and the speech will follow the active output. The destination value is preserved
        // here so future versions can route explicitly when an API becomes available.
        _ = destination
        // Two bindings each with a phrase, pressed together, used to leave
        // only the second one heard. A phrase is cut off only by itself
        // (a held or hammered button says it once, from the start);
        // another binding's phrase lines up behind it, at most two deep,
        // so a hammered pair does not pile up a minute of speech.
        if phrase == speakingPhrase {
            speech.stopSpeaking(at: .immediate)
            systemSpeech.stopSpeaking()
            pendingSystemPhrases.removeAll()
            voiceUtterances.removeAll()
        } else if max(voiceQueued - 1, 0) + pendingSystemPhrases.count >= Self.pendingCap {
            return
        }
        Self.lastSpokenNormalized = ScreenTextWatch.normalized(phrase)
        // Every phrase said while the window is open counts as an echo, not
        // only the newest queued one: "reload jump" with rows that each speak
        // their word pressed reload again, and could loop. A closed window
        // starts the list over.
        if CACurrentMediaTime() >= Self.speakingUntil { Self.spokenInWindow = [] }
        Self.spokenInWindow.append(ScreenTextWatch.normalized(phrase))
        // Heard from now; the delegate's start notice extends it to the
        // utterance and its finish notice closes it. A short window here
        // covers the synthesizer's start-up without blocking voice
        // phrases for long when nothing ends up spoken.
        Self.speakingUntil = max(Self.speakingUntil, CACurrentMediaTime() + Self.speakingLead)

        let chosen = UserDefaults.standard.string(forKey: Self.voiceKey) ?? ""
        if !chosen.isEmpty, let voice = resolvedVoice(chosen: chosen) {
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.rate = rate
            utterance.voice = voice
            if voiceQueued == 0 { speakingPhrase = phrase }
            voiceUtterances.insert(ObjectIdentifier(utterance))
            speech.speak(utterance)
        } else if appText, let voice = resolvedVoice(chosen: "") {
            // The System Voice speaks another language than the app shows:
            // an English voice asked to read Japanese said nothing useful.
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = voice
            // The speaking rate from Spoken Content, as the System Voice uses.
            utterance.prefersAssistiveTechnologySettings = true
            if voiceQueued == 0 { speakingPhrase = phrase }
            voiceUtterances.insert(ObjectIdentifier(utterance))
            speech.speak(utterance)
        } else if systemSpeech.isSpeaking {
            pendingSystemPhrases.append(phrase)
        } else {
            speakingPhrase = phrase
            systemSpeech.startSpeaking(phrase)
        }
    }

    /// Words the Mac says outside this service, VoiceOver reading out
    /// "Heard jump": the same echo, with nothing here to open the window.
    static func noteSpokenElsewhere(_ phrase: String) {
        if CACurrentMediaTime() >= speakingUntil { spokenInWindow = [] }
        spokenInWindow.append(ScreenTextWatch.normalized(phrase))
        speakingUntil = max(speakingUntil, CACurrentMediaTime() + 1.5)
    }

    /// An utterance ended or was cut: the next System Voice phrase, if one
    /// waits, and otherwise the echo window closes a moment from now.
    /// Counted by the utterance: a cut phrase's late cancel used to take
    /// one off the count of the phrase that replaced it.
    fileprivate func speechEnded(voiceUtterance: ObjectIdentifier? = nil) {
        if let voiceUtterance { voiceUtterances.remove(voiceUtterance) }
        if !pendingSystemPhrases.isEmpty, !systemSpeech.isSpeaking {
            let next = pendingSystemPhrases.removeFirst()
            speakingPhrase = next
            systemSpeech.startSpeaking(next)
            return
        }
        guard !speech.isSpeaking, !systemSpeech.isSpeaking else { return }
        speakingPhrase = nil
        Self.speakingUntil = CACurrentMediaTime() + Self.speakingTail
    }

    /// An utterance started: heard until it ends, at the latest the cap.
    fileprivate func speechStarted(phrase: String? = nil) {
        if let phrase { speakingPhrase = phrase }
        Self.speakingUntil = max(Self.speakingUntil, CACurrentMediaTime() + Self.speakingCap)
    }

    /// The voice the last press resolved, with what it was resolved from.
    /// Resolving runs the voice enumeration through the speech daemon
    /// (`speechVoices()`, `attributes(forVoice:)`, two language lookups),
    /// and it ran on every Speak press, inside the poll frame, so that
    /// frame and every other row's outputs in it waited on it. Now a press
    /// costs two defaults reads and three string compares; the enumeration
    /// runs again only when the app language, the chosen voice or the
    /// Mac's System Voice has changed since.
    private var voiceCache: (app: String, chosen: String, systemVoice: String, voice: AVSpeechSynthesisVoice?)?

    /// The chosen voice (`chosen` non-empty), or the app-language voice for
    /// the app's own words when the System Voice speaks another language
    /// (nil when they match, so the System Voice reads them).
    private func resolvedVoice(chosen: String) -> AVSpeechSynthesisVoice? {
        let app = AppLanguage.current
        let systemVoice = chosen.isEmpty ? systemSpeech.defaultVoiceID : ""
        if let hit = voiceCache, hit.app == app, hit.chosen == chosen, hit.systemVoice == systemVoice {
            return hit.voice
        }
        let voice = chosen.isEmpty ? Self.appLanguageVoiceIfSystemDiffers() : AVSpeechSynthesisVoice(identifier: chosen)
        voiceCache = (app, chosen, systemVoice, voice)
        return voice
    }

    /// Resolve the voice and build the System Voice synthesizer now, so the
    /// first Speak press of a run does not do it inside the poll loop.
    /// Called by the engine when the preset it starts has a Speak row.
    func prepareSpeech() {
        #if DEBUG
        if TestCapture.active { return }
        #endif
        _ = systemSpeech
        _ = resolvedVoice(chosen: UserDefaults.standard.string(forKey: Self.voiceKey) ?? "")
    }

    /// The best installed voice for the app's language, when the System
    /// Voice is in a different one; nil when they match.
    static func appLanguageVoiceIfSystemDiffers() -> AVSpeechSynthesisVoice? {
        let app = String(AppLanguage.current.prefix(2))
        let systemLocale = FeedbackService.shared.systemSpeech.defaultVoiceLocale
        guard !systemLocale.isEmpty, !systemLocale.hasPrefix(app) else { return nil }
        let novelty = "com.apple.speech.synthesis.voice."
        // The app's own region first: Brazilian text in a European voice,
        // or Mandarin in a Cantonese one, read wrongly.
        let region: String = {
            switch AppLanguage.current {
            case "zh-Hans": return "zh-CN"
            case "zh-Hant": return "zh-TW"
            case "pt-BR": return "pt-BR"
            default: return AVSpeechSynthesisVoice(language: app)?.language ?? app
            }
        }()
        let localeDefault = AVSpeechSynthesisVoice(language: region)?.identifier
        // Eloquence character voices (Grandpa, Shelley) are not a reading voice.
        let characters: Set<String> = ["Eddy", "Flo", "Grandma", "Grandpa", "Reed", "Rocko", "Sandy", "Shelley"]
        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int, Int) {
            (v.language == region ? 1 : 0, v.quality.rawValue, v.identifier == localeDefault ? 1 : 0)
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(app) && !$0.identifier.hasPrefix(novelty) && !characters.contains($0.name) }
            .max { rank($0) < rank($1) }
    }

    /// Cancel any ongoing speech.
    func stopSpeaking() {
        pendingSystemPhrases.removeAll()
        speech.stopSpeaking(at: .immediate)
        systemSpeech.stopSpeaking()
        voiceUtterances.removeAll()
        speakingPhrase = nil
    }
}

/// Delegate for both synthesizers. Their callbacks can arrive off the main
/// thread, so each hops to the main actor before touching the service.
private final class SpeechWatcher: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let phrase = utterance.speechString
        Task { @MainActor in FeedbackService.shared.speechStarted(phrase: phrase) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in FeedbackService.shared.speechEnded(voiceUtterance: id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in FeedbackService.shared.speechEnded(voiceUtterance: id) }
    }

}

/// What the service asks of the System Voice synthesizer.
private protocol SystemVoiceSpeaking: AnyObject {
    var isSpeaking: Bool { get }
    func startSpeaking(_ phrase: String)
    func stopSpeaking()
    /// The identifier of the voice chosen in Accessibility, Spoken Content.
    var defaultVoiceID: String { get }
    /// That voice's locale identifier, or "" when it has none.
    var defaultVoiceLocale: String { get }
}

/// The System Voice. NSSpeechSynthesizer with no voice set is the one API
/// that follows the Spoken Content choice, including the enhanced and
/// premium voices installed there; AVSpeechSynthesizer's default is the
/// compact voice for the locale, which is the one people find hard to
/// understand. Apple deprecated it in macOS 14 and it still works; every
/// use of it is in this class, so the deprecation is noted once, where the
/// instance is made.
@available(macOS, deprecated: 14.0, message: "kept on purpose: the one synthesizer that speaks with the Spoken Content voice")
private final class SystemVoice: NSObject, SystemVoiceSpeaking, NSSpeechSynthesizerDelegate {
    private let synth = NSSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }
    func startSpeaking(_ phrase: String) { synth.startSpeaking(phrase) }
    func stopSpeaking() { synth.stopSpeaking() }
    var defaultVoiceID: String { NSSpeechSynthesizer.defaultVoice.rawValue }
    var defaultVoiceLocale: String {
        NSSpeechSynthesizer.attributes(forVoice: NSSpeechSynthesizer.defaultVoice)[.localeIdentifier] as? String ?? ""
    }

    // The callbacks can arrive off the main thread, so each hops to the
    // main actor before touching the service.
    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in FeedbackService.shared.speechEnded() }
    }

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord characterRange: NSRange, of string: String) {
        Task { @MainActor in FeedbackService.shared.speechStarted() }
    }
}
