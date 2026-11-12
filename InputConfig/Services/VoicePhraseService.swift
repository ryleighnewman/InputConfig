import Foundation
import AVFoundation
import CoreAudio
import AppKit
import QuartzCore
import Speech

/// Listens for a preset's voice phrases (`VoicePhrase`) with the Mac's own
/// speech recognizer and says when a `.voicePhrase` row has just been
/// heard. Recognition runs on this Mac when the language supports it
/// (`supportsOnDeviceRecognition`); otherwise Apple's servers do it, and
/// the sheet says so. Listening is ref-counted: only while a preset with
/// voice rows runs or the Voice Phrases sheet is open is the microphone
/// open. Apple ends a recognition task after about a minute, so the task
/// is restarted on a timer and whenever it ends on its own.
///
/// Needs the Microphone and Speech Recognition permissions
/// (`VoicePermission`); the service asks for both the first time listening
/// is wanted and never asked before, and says once in the activity log
/// when one is missing.
@MainActor
final class VoicePhraseService: ObservableObject {
    static let shared = VoicePhraseService()

    @Published private(set) var phrases: [VoicePhrase] = []
    /// What the recognizer heard in the current stretch of speech.
    @Published private(set) var transcript: String = ""
    @Published private(set) var listening = false
    /// Why listening is not possible right now, for the sheet; nil when it is.
    @Published private(set) var problem: String?
    /// When each phrase was last heard (system uptime), for the sheet's dot.
    @Published private(set) var lastHeard: [UUID: TimeInterval] = [:]
    /// True when the chosen language is recognized on this Mac.
    @Published private(set) var onDevice = false

    static let localeKey = "InputConfig.voiceLocale"
    /// The recognizer's language: the chosen one, or the Mac's.
    static var locale: Locale {
        if let id = UserDefaults.standard.string(forKey: localeKey), !id.isEmpty { return Locale(identifier: id) }
        return Locale.current
    }
    static func setLocale(_ locale: Locale?) {
        UserDefaults.standard.set(locale?.identifier ?? "", forKey: localeKey)
    }

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    /// Capture from the microphone chosen in Settings; nil while listening
    /// through the engine on the system default.
    private var direct: DirectMicInput?
    #if DEBUG
    var debugDirectStats: String {
        guard let d = direct else { return "direct=off" }
        let st = d.stats
        return "direct=\(d.deviceUID ?? "?") format=\(d.format.map { "\($0.sampleRate) \($0.channelCount)ch" } ?? "?") buffers=\(st.buffers) peak=\(String(format: "%.1f dB", 20 * log10(max(st.peak, 1e-9))))"
    }
    #endif

    /// The microphone voice phrases listen to, by its CoreAudio UID; nil or
    /// empty for the system default.
    static let microphoneKey = "InputConfig.voiceMicrophoneUID"
    /// Its name when chosen, shown while it is not connected.
    static let microphoneNameKey = "InputConfig.voiceMicrophoneName"
    static var chosenMicrophoneUID: String? {
        let uid = UserDefaults.standard.string(forKey: microphoneKey) ?? ""
        return uid.isEmpty ? nil : uid
    }
    /// Settings changed the microphone: listening, if on, starts over on it.
    func microphoneChanged() { restartListening(keepingAudio: false) }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// What the input tap appends to; a task restart swaps the request in
    /// it and leaves the engine and the tap running.
    private var sink: RequestSink?
    private var retainCount = 0
    private var restartTimer: Timer?
    /// Whether the input tap is on the engine's input node. The node is
    /// touched only when it is, since asking for it on a Mac with no audio
    /// input can throw.
    private var tapInstalled = false
    /// After a problem (the recognizer away, the microphone busy, a
    /// permission still to come) listening is tried again, 3 s later and
    /// then twice as long each time up to 30 s, while someone wants it.
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval = VoicePhraseService.firstRetrySeconds
    /// The presses still to come or under way for each phrase, as (start,
    /// end) uptimes: "jump jump" in one result queues two, a gap apart, so
    /// each is its own press at the engine's poll.
    private var pulses: [UUID: [(start: TimeInterval, end: TimeInterval)]] = [:]
    /// How many times each phrase has been counted in the current transcript,
    /// so a phrase fires once per time it is said, not once per partial result.
    private var seen: [UUID: Int] = [:]
    /// The speaking window (FeedbackService.speakingUntil) whose echo drop
    /// was logged, so a long utterance is noted once.
    private var echoDropLoggedWindow: TimeInterval = 0
    private var saidProblem = false
    private var generation = 0
    /// The permission prompts go up once per launch at most, from here.
    private var askedForPermissions = false
    /// When the current task began and whether it has returned any text,
    /// so a task that dies at once (the on-device model not installed, the
    /// server path offline) is treated as a problem with the backed-off
    /// retry rather than restarted three times a second.
    private var taskStartedAt: TimeInterval = 0
    private var taskProducedText = false
    /// Hears the recognizer come and go (the server path dropping, the
    /// on-device model arriving).
    private lazy var availabilityWatcher = AvailabilityWatcher { [weak self] available in
        Task { @MainActor in self?.availabilityChanged(available) }
    }

    static let pulseSeconds: TimeInterval = 0.15
    /// The release between two queued presses, longer than a poll.
    static let pulseGapSeconds: TimeInterval = 0.05
    /// Restart before Apple's one minute limit ends the task.
    static let restartSeconds: TimeInterval = 50
    static let firstRetrySeconds: TimeInterval = 3
    static let maxRetrySeconds: TimeInterval = 30
    /// A task that ends in error sooner than this, with nothing heard,
    /// never really ran.
    static let shortTaskSeconds: TimeInterval = 2

    /// Published, so the visualizer's list redraws when listening starts
    /// or stops; follows `retainCount`.
    @Published private(set) var isTracking = false

    private var suspended = false

    private init() {
        // The input device changed (headset plugged in, the default input
        // switched): the engine stops itself, so listen again on the new one.
        // Posted on the engine's own thread, which can wait for main: taken
        // there (queue nil) and hopped to main, never run synchronously on
        // main while main waits in the engine's start or stop. Debounced, as
        // a route change can post several in a row.
        watchDeviceList()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.routeChangeGeneration &+= 1
                let mine = self.routeChangeGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.routeChangeGeneration == mine else { return }
                    self.restartListening(keepingAudio: false)
                }
            }
        }
    }

    /// The latest route change; an earlier one's restart is dropped.
    private var routeChangeGeneration = 0
    /// The chosen microphone last reported missing, so the log says it once.
    private var lastMissingMicrophone: String?

    /// A microphone came or went: with one chosen in Settings, listening
    /// moves to it when it arrives and to the default when it leaves.
    private func watchDeviceList() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, Self.chosenMicrophoneUID != nil else { return }
                let present = Self.chosenMicrophoneUID.flatMap { AudioInputDevices.device(forUID: $0) } != nil
                let onIt = self.direct != nil
                if present != onIt {
                    if present { self.lastMissingMicrophone = nil }
                    self.restartListening(keepingAudio: false)
                }
            }
        }
    }

    // MARK: - The preset's phrases

    func load(_ list: [VoicePhrase]) {
        // The editor reloads on open and after Save; the same phrases
        // again would restart the recognizer and lose the counts for
        // nothing. Only a changed set does.
        let list = Array(list.prefix(VoicePhrase.maxPhrases))
        guard list != phrases else { return }
        phrases = list
        // The transcript goes too: a reload while listening would count
        // the phrases in it again and fire them. Clearing it is not enough
        // while a task is live, since its next partial brings back the
        // whole cumulative text; a fresh task starts from an empty one.
        seen = [:]; pulses = [:]; lastHeard = [:]; transcript = ""
        if listening || task != nil { restartListening(keepingAudio: true) }
    }

    func allPhrases() -> [VoicePhrase] { phrases }

    func phrase(with id: UUID) -> VoicePhrase? { phrases.first { $0.id == id } }

    func upsert(_ phrase: VoicePhrase) {
        let old = phrases.first { $0.id == phrase.id }
        if let i = phrases.firstIndex(where: { $0.id == phrase.id }) { phrases[i] = phrase }
        else if phrases.count < VoicePhrase.maxPhrases { phrases.append(phrase) }
        // New words start from the transcript as it stands: what was said
        // before they were typed is not a fresh saying, and the old words'
        // count must not carry over to the new ones.
        if old?.phrase != phrase.phrase {
            seen[phrase.id] = Self.occurrences(of: phrase.phrase, in: transcript)
            pulses[phrase.id] = nil
            lastHeard[phrase.id] = nil
        }
    }

    func delete(_ id: UUID) {
        phrases.removeAll { $0.id == id }
        seen[id] = nil; pulses[id] = nil; lastHeard[id] = nil
    }

    var nextColorIndex: Int { phrases.count % 8 }

    // MARK: - Listening

    func beginTracking() {
        retainCount += 1
        isTracking = retainCount > 0
        guard retainCount == 1 else { return }
        saidProblem = false
        retryDelay = Self.firstRetrySeconds
        startListening()
    }

    func endTracking() {
        retainCount = max(0, retainCount - 1)
        isTracking = retainCount > 0
        guard retainCount == 0 else { return }
        stopListening()
        pulses = [:]; seen = [:]
        // What was heard is not kept for the rest of the run.
        transcript = ""; lastHeard = [:]
    }

    /// Held back by Only in these apps, the lock or a user switch: the
    /// microphone closes, the retain stays, and resuming listens again.
    /// Open, it went on hearing (and for a language not on the Mac, sending
    /// to Apple's servers) with nothing the rows could do.
    func setSuspended(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        guard retainCount > 0 else { return }
        if on {
            stopListening()
            pulses = [:]; seen = [:]; transcript = ""; lastHeard = [:]
        } else {
            startListening()
        }
    }

    /// The language changed in the sheet: listen again in the new one.
    func restartForLanguage() { restartListening(keepingAudio: true) }

    /// `keepingAudio`: only the task and its request start over, and the
    /// engine and its tap run on. False after a route change, where the
    /// engine stopped itself and the input may be another device.
    private func restartListening(keepingAudio: Bool) {
        guard retainCount > 0 else { return }
        stopListening(keepingAudio: keepingAudio); startListening(keepingAudio: keepingAudio)
    }

    /// The recognizer came or went while listening was wanted.
    private func availabilityChanged(_ available: Bool) {
        guard retainCount > 0 else { return }
        if available {
            guard !listening else { return }
            retryTimer?.invalidate(); retryTimer = nil
            startListening()
        } else if listening {
            stopListening()
            setProblem(Self.notAvailableText())
        }
    }

    func isPressed(_ id: UUID) -> Bool {
        // Gated on tracking, not on listening: a final result queues its
        // pulse and then stops listening for the 0.3 s restart, and the
        // pulse still has to press. endTracking clears the pulses.
        guard retainCount > 0, let windows = pulses[id] else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        return windows.contains { $0.start <= now && now < $0.end }
    }

    /// The sheet's text for a recognizer that is not there for the language.
    private static func notAvailableText() -> String {
        let locale = Self.locale
        return String(localized: "Speech recognition is not available for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) right now")
    }

    /// `keepingAudio`: a task restart (the 50 s timer, a final result, a
    /// new phrase set or language) keeps a running engine and tap and swaps
    /// the new request into the tap's sink. Stopping and starting the engine
    /// for it held main 58 to 234 ms each time. The first start, and any
    /// start after the engine stopped, starts it as before.
    private func startListening(keepingAudio: Bool = false) {
        guard !suspended else { return }
        // Reused only while it runs as the policy wants it: voice processing
        // changes the input format, so a change of it takes the full start.
        let reuse = keepingAudio && sink != nil
            && ((direct?.isRunning ?? false)
                || (audioEngine.isRunning && tapInstalled && audioEngine.inputNode.isVoiceProcessingEnabled == Self.voiceProcessing))
        // Whatever was running ends first: a delayed restart and a new
        // tracking run could otherwise each start a task and a tap.
        tearDownTask()
        if !reuse { tearDownAudio() }
        // Every way out below that does not end with a task listening closes
        // the microphone, as the full tear down at the top used to.
        var started = false
        defer { if !started { tearDownAudio() } }
        generation += 1
        let gen = generation
        // Never asked yet: ask now, the first time a voice preset starts,
        // which is what the Help says happens. Until the app has asked
        // once, macOS does not even list it in those Privacy panes, so
        // sending the person there would be a dead end. The answer comes
        // back through this same path and listens or says what is missing.
        if !askedForPermissions,
           AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            || SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            askedForPermissions = true
            VoicePermission.request { [weak self] in
                guard let self, self.retainCount > 0, self.generation == gen else { return }
                self.startListening()
            }
            return
        }
        guard VoicePermission.microphoneAllowed, VoicePermission.speechAllowed else {
            setProblem(String(localized: "Voice phrases need the Microphone and Speech Recognition permissions for InputConfig in System Settings, Privacy & Security; until then they read as not heard"))
            return
        }
        let locale = Self.locale
        guard let r = SFSpeechRecognizer(locale: locale) else {
            setProblem(Self.notAvailableText())
            return
        }
        // Kept, with the watcher on it, even when it is not available yet,
        // so its coming back starts listening.
        recognizer = r
        r.delegate = availabilityWatcher
        guard r.isAvailable else {
            setProblem(Self.notAvailableText())
            return
        }
        onDevice = r.supportsOnDeviceRecognition
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        if reuse {
            // The engine and the tap run on; the tap appends to this request
            // from its next buffer.
            sink?.swap(req)
        } else if let uid = Self.chosenMicrophoneUID, let device = AudioInputDevices.device(forUID: uid) {
            // The microphone chosen in Settings, held by its own capture: the
            // engine would drift back to the system default.
            let sink = RequestSink(req)
            let mic = DirectMicInput()
            do {
                try mic.start(deviceID: device.id, deviceUID: device.uid) { buffer in sink.append(buffer) }
            } catch {
                setProblem(String(localized: "The microphone could not be opened: \(String(describing: error))"))
                return
            }
            direct = mic
            self.sink = sink
        } else {
            if let uid = Self.chosenMicrophoneUID, uid != lastMissingMicrophone {
                // Chosen but not connected: the system default until it is back.
                lastMissingMicrophone = uid
                ActivityLog.shared.warning("Voice", "The microphone chosen in Settings is not connected; listening on the system default")
            }
            // The engine's input node is created on first touch and can throw
            // when the Mac has no audio input at all, so look for one first.
            guard AVCaptureDevice.default(for: .audio) != nil else {
                setProblem(String(localized: "No microphone is available"))
                return
            }
            let input = audioEngine.inputNode
            // Voice processing (off, see `voiceProcessing`) changes the
            // input format, so it is set before the format is read; a node
            // left with it on from an earlier session is turned back.
            if input.isVoiceProcessingEnabled != Self.voiceProcessing {
                do { try input.setVoiceProcessingEnabled(Self.voiceProcessing) } catch {}
            }
            // Voice processing also turns other audio down while it runs, which
            // for a voice preset was the whole session: the least ducking keeps
            // the game's or the music's volume where it was.
            if input.isVoiceProcessingEnabled {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                setProblem(String(localized: "No microphone is available"))
                return
            }
            let sink = RequestSink(req)
            input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tapBlock(sink))
            self.sink = sink
            tapInstalled = true
            audioEngine.prepare()
            do { try audioEngine.start() } catch {
                input.removeTap(onBus: 0)
                tapInstalled = false
                setProblem(String(localized: "The microphone could not be opened: \(error.localizedDescription)"))
                return
            }
        }
        started = true
        problem = nil
        listening = true
        transcript = ""; seen = [:]
        taskStartedAt = ProcessInfo.processInfo.systemUptime
        taskProducedText = false
        task = r.recognitionTask(with: req, resultHandler: Self.resultHandler(generation: gen, service: self))
        restartTimer?.invalidate()
        let t = Timer(timeInterval: Self.restartSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.listening { self.stopListening(keepingAudio: true); self.startListening(keepingAudio: true) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        restartTimer = t
    }

    /// `keepingAudio`: the engine and the tap stay for the start that
    /// follows (a task restart); every other stop closes the microphone.
    private func stopListening(keepingAudio: Bool = false) {
        tearDownTask()
        if !keepingAudio { tearDownAudio() }
        retryTimer?.invalidate(); retryTimer = nil
        listening = false
    }

    /// Ends the task and the request, leaving the engine, the tap and the
    /// published state alone.
    private func tearDownTask() {
        generation += 1
        restartTimer?.invalidate(); restartTimer = nil
        task?.cancel(); task = nil
        // Out of the sink first, so the tap appends nothing after endAudio.
        sink?.swap(nil)
        request?.endAudio(); request = nil
    }

    /// Stops the engine and takes the tap off.
    private func tearDownAudio() {
        direct?.stop(); direct = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        sink = nil
    }

    /// Off. Apple's voice processing failed on every buffer on macOS 27
    /// ("failed to run downlink DSP (I/O fault)", Nov 7 2026), so phrases
    /// went unheard, and while it ran it turned other audio down and
    /// switched the speaker's mute. The app's own spoken output is kept out
    /// in software instead: words heard while it speaks do not fire
    /// (FeedbackService.speakingUntil, in handle). A different answer takes
    /// the full engine start, since it changes the input format.
    private static let voiceProcessing = false

    private func handle(generation gen: Int, text: String?, isFinal: Bool, failure: String?, unavailable: Bool) {
        guard gen == generation else { return }   // an older task's late result
        if let text {
            transcript = text
            if !text.isEmpty, !taskProducedText {
                // The task works: the next problem starts the backoff over.
                taskProducedText = true
                retryDelay = Self.firstRetrySeconds
            }
            // Words that arrived while the app itself was speaking may be
            // its own voice coming back through the microphone: the phrase
            // it said is shown, counted as seen so it does not fire later,
            // but not pressed. Any other phrase is the person's.
            match(fire: CACurrentMediaTime() >= FeedbackService.speakingUntil)
        }
        if isFinal || failure != nil {
            guard listening else { return }
            let ran = ProcessInfo.processInfo.systemUptime - taskStartedAt
            if !taskProducedText, ran < Self.shortTaskSeconds {
                // The task died at once with nothing heard: tried again
                // later with the backoff, not a fast restart. An error is
                // shown in the sheet; a final result with no text is not.
                stopListening()
                if let failure { setProblem(unavailable ? Self.notAvailableText() : failure) } else { scheduleRetry() }
                return
            }
            // The task ended (silence, the one minute limit, an error after
            // a real run): listen again, from an empty transcript.
            if ran >= Self.shortTaskSeconds { retryDelay = Self.firstRetrySeconds }
            // The microphone stays open through the 0.3 s; the tap's buffers
            // go nowhere until the next task's request is swapped in.
            stopListening(keepingAudio: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    // Unless something else (a language change, a new
                    // tracking run) started listening again in the meantime.
                    // Whatever stopped tracking or suspended in the meantime
                    // closed the microphone itself.
                    if let self, self.retainCount > 0, !self.listening, self.task == nil { self.startListening(keepingAudio: true) }
                }
            }
        }
    }

    /// Siri just took a request and is answering aloud: neither the request
    /// nor the answer is a phrase said to a row.
    func holdForSpokenReply() { spokenReplyUntil = ProcessInfo.processInfo.systemUptime + 4 }
    private var spokenReplyUntil: TimeInterval = 0

    /// A phrase fires once for each new time it is found in the transcript:
    /// its words in a row at some word of the transcript, so "jump jump"
    /// counts twice. A partial result the recognizer rewrites can drop a
    /// phrase it had; the count kept is the highest seen, so the phrase
    /// does not fire again when the words come back.
    private func match(fire: Bool = true) {
        let words = Self.words(of: transcript)
        let now = ProcessInfo.processInfo.systemUptime
        // While the app speaks, only the phrase it is saying is an echo.
        let spoken = fire ? nil : FeedbackService.spokenInWindow.map { $0.split(separator: " ") }
        for p in phrases {
            let phraseWords = Self.words(of: p.phrase)
            let count = Self.occurrences(of: phraseWords, in: words)
            let before = seen[p.id, default: 0]
            guard count > before else { continue }
            if now < spokenReplyUntil {
                seen[p.id] = count
                continue
            }
            if let spoken, spoken.contains(where: { Self.occurrences(of: phraseWords, in: $0) > 0 }) {
                seen[p.id] = count
                let window = FeedbackService.speakingUntil
                if window != echoDropLoggedWindow {
                    echoDropLoggedWindow = window
                    ActivityLog.shared.info("Voice", "Heard \(p.shownName) while the app was saying it; not pressed")
                }
                continue
            }
            seen[p.id] = count
            // One press per new time it was said, after the ones still queued.
            var windows = pulses[p.id, default: []].filter { now < $0.end }
            var start = windows.last.map { $0.end + Self.pulseGapSeconds } ?? now
            for _ in before..<count {
                windows.append((start, start + Self.pulseSeconds))
                start += Self.pulseSeconds + Self.pulseGapSeconds
            }
            pulses[p.id] = windows
            lastHeard[p.id] = now
            ActivityLog.shared.info("Voice", "Heard \(p.shownName)")
        }
    }

    /// The words of a phrase or a transcript, normalized the way screen
    /// text is (case, accents, punctuation and extra spaces folded away).
    /// The tap's block, made outside the main actor. Written inline in
    /// startListening it inherited the main actor, and Swift's isolation
    /// check stopped the app the first time the audio thread called it.
    nonisolated private static func tapBlock(_ sink: RequestSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }

    /// The recognizer's result handler, made outside the main actor for the
    /// same reason: inline it inherited the main actor and was safe only
    /// while the recognizer's queue stayed the main one.
    nonisolated private static func resultHandler(generation gen: Int, service: VoicePhraseService)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak service] result, error in
            let text = result?.bestTranscription.formattedString
            // No speech heard, a retry asked for, a task canceled: no fault,
            // and not the language missing. The task just ended.
            let quiet = (error as NSError?).map { $0.domain == "kAFAssistantErrorDomain" && [203, 216, 1110].contains($0.code) } ?? false
            let isFinal = (result?.isFinal ?? false) || quiet
            let failure = quiet ? nil : error?.localizedDescription
            // Apple's assistant layer fails with its raw domain name as the
            // text; it means the recognizer is not there for the language.
            let unavailable = (error as NSError?).map {
                $0.domain == "kAFAssistantErrorDomain" || $0.localizedDescription.contains("kAFAssistantErrorDomain")
            } ?? false
            Task { @MainActor in
                service?.handle(generation: gen, text: text, isFinal: isFinal, failure: failure, unavailable: unavailable)
            }
        }
    }

    nonisolated static func words(of text: String) -> [Substring] {
        ScreenTextWatch.normalized(text).split(separator: " ")
    }

    /// How many times `wanted` appears as a run of whole words in `words`:
    /// "jump" in "jump jump" is 2, "jump" in "jumping" is 0. Pure, so the
    /// Test Bench can check it without a microphone.
    nonisolated static func occurrences(of wanted: [Substring], in words: [Substring]) -> Int {
        guard !wanted.isEmpty, wanted.count <= words.count else { return 0 }
        var count = 0
        for i in 0...(words.count - wanted.count) where words[i..<(i + wanted.count)].elementsEqual(wanted) { count += 1 }
        return count
    }

    /// `occurrences(of:in:)` on raw text.
    nonisolated static func occurrences(of phrase: String, in transcript: String) -> Int {
        occurrences(of: words(of: phrase), in: words(of: transcript))
    }

    private func setProblem(_ text: String) {
        problem = text
        listening = false
        if !saidProblem { saidProblem = true; ActivityLog.shared.warning("Voice", text) }
        scheduleRetry()
    }

    /// Tries again after a problem, later each time, while listening is
    /// still wanted: a permission granted from Settings, a recognizer
    /// that comes back, a microphone that frees up.
    private func scheduleRetry() {
        guard retainCount > 0, retryTimer == nil else { return }
        let t = Timer(timeInterval: retryDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.retryTimer = nil
                guard self.retainCount > 0, !self.listening else { return }
                self.startListening()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
        retryDelay = min(Self.maxRetrySeconds, retryDelay * 2)
    }

    /// Languages the recognizer offers, by name, the Mac's first.
    static func supportedLocales() -> [Locale] {
        let all = SFSpeechRecognizer.supportedLocales()
        let name: (Locale) -> String = { Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier }
        return all.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// The recognizer's delegate, which an NSObject has to be; it only
    /// passes availability changes on.
    private final class AvailabilityWatcher: NSObject, SFSpeechRecognizerDelegate {
        let changed: @Sendable (Bool) -> Void
        init(_ changed: @escaping @Sendable (Bool) -> Void) { self.changed = changed }
        nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
            changed(available)
        }
    }

    /// The request, handed to the audio tap, which runs on the audio thread.
    /// Swapped from main when only the task restarts; nil drops the buffers
    /// (between a final result and the next task).
    private final class RequestSink: @unchecked Sendable {
        private let lock = NSLock()
        /// Guarded by `lock`: written on main, read on the audio thread.
        private var request: SFSpeechAudioBufferRecognitionRequest?
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
        func swap(_ new: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = new; lock.unlock() }
        /// Appended under the lock, so a request swapped out gets no buffer
        /// after its endAudio.
        func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
    }
}

/// The two permissions voice phrases need. Neither posts a change
/// notification; callers re-check when they appear and after a request.
enum VoicePermission {
    static var microphoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var microphoneDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }
    static var speechAllowed: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static var speechDenied: Bool {
        let s = SFSpeechRecognizer.authorizationStatus()
        return s == .denied || s == .restricted
    }

    /// Asks for both, one after the other; `completion` runs on the main
    /// actor when both have answered.
    static func request(completion: @escaping @MainActor () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            SFSpeechRecognizer.requestAuthorization { _ in
                Task { @MainActor in completion() }
            }
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
    static func openSpeechSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") { NSWorkspace.shared.open(url) }
    }
}
