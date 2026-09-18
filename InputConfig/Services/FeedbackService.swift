import Foundation
import AVFoundation
import AppKit
import GameController
import CoreHaptics

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

    private init() {}

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
    /// so the result can be reported by colour instead of by counting:
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
                      _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                NSLog("[BUZZ] %@", name)
                writer.startHold(red: r, green: g, blue: b)
            }
            // The colour goes up first and stays; the buzz follows half a
            // second later so there is no doubt which one it belongs to.
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.5, execute: body)
        }
        NSLog("[BUZZ] five attempts, each with its own light bar colour")
        announce("1 red: haptics, our writes running", 255, 0, 0, at: 0.2) {
            self.vibrateViaHaptics(controller: controller, intensity: 1.0, durationMs: ms)
        }
        announce("2 green: haptics, our writes paused", 0, 255, 0, at: 2.2) {
            writer.pauseWrites(forMs: ms + 600)
            self.vibrateViaHaptics(controller: controller, intensity: 1.0, durationMs: ms)
        }
        announce("3 blue: our own output report", 0, 0, 255, at: 4.2) {
            writer.vibrate(intensity: 1.0, durationMs: ms)
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
        // Sony pads buzz through the report this app already writes for the
        // light bar. Asking the system to play the haptic hands it the
        // controller's report stream and it repaints the light bar for as
        // long as it holds it, which nothing this app writes can outrun: the
        // preset's colour was replaced on every press that buzzed. Carrying
        // the motor values ourselves means one writer and one colour.
        let name = ((controller.vendorName ?? "") + " " + controller.productCategory).lowercased()
        let sony = name.contains("dualsense") || name.contains("dualshock")
        let owned = InProcessLightWriter.shared.ownsAnyDualSense
        if sony, owned {
            // A duration of 0 means "a tap", but a motor needs time to spin
            // up, so a tap gets a short pulse rather than nothing felt.
            let ms = durationMs > 0 ? max(durationMs, Self.rumblePulseMs) : Self.rumblePulseMs
            Self.debugLastPath = "report intensity=\(intensity) ms=\(ms) name=\(name)"
            InProcessLightWriter.shared.vibrate(intensity: intensity, durationMs: ms)
            return
        }
        Self.debugLastPath = "apple intensity=\(intensity) ms=\(durationMs) sony=\(sony) owned=\(owned) name=\(name)"
        vibrateUsingEngine(controller: controller, intensity: intensity, sharpness: sharpness, durationMs: durationMs)
    }

    private func vibrateUsingEngine(controller: GCController, intensity: Float, sharpness: Float, durationMs: Int) {
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

    /// Speaks with the System Voice. NSSpeechSynthesizer with no voice set
    /// is the one API that follows the Spoken Content choice, including the
    /// enhanced and premium voices installed there; AVSpeechSynthesizer's
    /// default is the compact voice for the locale, which is the one people
    /// find hard to understand.
    private lazy var systemSpeech = NSSpeechSynthesizer()

    /// Every installed voice for the user's languages, premium first.
    static func installedVoices() -> [AVSpeechSynthesisVoice] {
        let preferred = Set(Locale.preferredLanguages.map { String($0.prefix(2)) })
        let novelty = "com.apple.speech.synthesis.voice."
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { preferred.contains(String($0.language.prefix(2))) && !$0.identifier.hasPrefix(novelty) }
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
    func speak(_ phrase: String, destination: SpeechDestination = .mac, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        guard !phrase.isEmpty else { return }
        // Note: on macOS there is no public API to pin speech to a specific output device.
        // The user can route audio to the controller speaker via System Settings > Sound,
        // and the speech will follow the active output. The destination value is preserved
        // here so future versions can route explicitly when an API becomes available.
        _ = destination
        speech.stopSpeaking(at: .immediate)
        systemSpeech.stopSpeaking()

        let chosen = UserDefaults.standard.string(forKey: Self.voiceKey) ?? ""
        if !chosen.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: chosen) {
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.rate = rate
            utterance.voice = voice
            speech.speak(utterance)
        } else {
            systemSpeech.startSpeaking(phrase)
        }
    }

    /// Cancel any ongoing speech.
    func stopSpeaking() {
        speech.stopSpeaking(at: .immediate)
        systemSpeech.stopSpeaking()
    }
}
