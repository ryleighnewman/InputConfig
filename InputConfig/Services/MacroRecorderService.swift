import Foundation
import AppKit
import Combine

/// Records keys and mouse buttons system-wide for the macro editor's
/// Record steps sheet, through the same monitors the external mouse and
/// keyboard inputs use (a listen-only tap and NSEvent monitors, on the
/// Accessibility permission). The app's own posted events carry a marker
/// and never reach the monitors, so a running preset cannot record itself.
///
/// Nothing is recorded while InputConfig is the app in front: the clicks
/// and the Command Tab that bring you back to the sheet are not steps.
///
/// Observable (1.10): each view re-runs for the properties it reads. The
/// recording panel reads the count and the pause state, and re-ran for
/// every step change and flag besides; bookkeeping is ignored, as it was
/// unpublished before.
@MainActor @Observable
final class MacroRecorderService {
    static let shared = MacroRecorderService()

    /// What was recorded. Not tracked: every edge redrew the sheet and
    /// the recording panel, though a pointer sample, a press still down or
    /// a move at the end changes no step. The views follow liveStepCount,
    /// liveStepsRevision (read through liveSteps) and hasEdges, set from
    /// the steps after a change.
    @ObservationIgnored private(set) var recording = MacroRecording() {
        didSet { recordingChanged() }
    }
    /// How many steps the recording makes, set only when it changes.
    private(set) var liveStepCount = 0
    /// Bumped when the steps change and their count does not (a hold
    /// measured at its release, a modifier folded onto a tap), so the
    /// sheet's list follows those too.
    private(set) var liveStepsRevision = 0
    /// Whether anything is recorded, for Start Over and Record More.
    private(set) var hasEdges = false
    private(set) var isRecording = false
    /// True while recording and InputConfig is the app in front.
    private(set) var paused = false
    /// Edges seen, taps counted once; the sheet's live count.
    private(set) var pressCount = 0
    /// A click is recorded with the pointer's position, as a Move pointer
    /// step before it, so it lands on the same spot when played.
    var recordClickPositions = true
    /// The pointer's path between clicks, sampled ten times a second.
    var recordPointerPath = false
    /// Scrolling, as Scroll steps.
    var recordScrolling = true
    /// The first click after leaving InputConfig only picks the window to
    /// work in, so it is not a step. Off, it is recorded like any other.
    var skipFirstClick = true
    /// A key that stops the recording from the other app, beside Escape
    /// twice (which always works). -1 is none. The key itself is never a
    /// step, so it should be one the macro does not use.
    static let stopKeyDefaultsKey = "InputConfig.recorder.stopKey"
    var stopKeyCode: Int = (UserDefaults.standard.object(forKey: MacroRecorderService.stopKeyDefaultsKey) as? Int) ?? -1 {
        didSet { UserDefaults.standard.set(stopKeyCode, forKey: Self.stopKeyDefaultsKey) }
    }
    /// Paused from the recording panel: nothing is recorded, and the time
    /// spent paused is not a wait.
    private(set) var userPaused = false
    /// Armed each time recording starts or InputConfig steps aside; a key
    /// press first disarms it (the window was already the one in front).
    @ObservationIgnored private var awaitingFirstClick = false
    /// When InputConfig last stopped being the app in front. The click
    /// that switched apps can reach the recorder just after the switch,
    /// so a press this soon after it is never a step.
    @ObservationIgnored private var resumedAt: Double = -1
    /// InputConfig hid itself for this take, so the app behind it came
    /// forward without a click; a stop from the other app brings it back.
    @ObservationIgnored private var hidForRecording = false
    /// Escape pressed twice within this long stops the recording, from
    /// any app, without coming back to the sheet.
    static let doubleEscapeSeconds = 0.4
    @ObservationIgnored private var lastEscapeAt: Double = -1
    /// The first Escape of a double press while paused, on the plain clock.
    @ObservationIgnored private var pausedEscapeAt: Double = -1
    @ObservationIgnored private var lastPathSampleAt: Double = -1
    /// Where the pointer was when each mouse button went down, so a press
    /// let go somewhere else records the move and plays as a drag.
    @ObservationIgnored private var pressPoints: [Int: (x: Double, y: Double)] = [:]
    /// Keys and buttons whose press this take recorded and whose release
    /// has not come: a release with no press here (the click or Command
    /// Tab that left InputConfig, let go after the app resigned) is not a
    /// step, so it neither records nor takes the resume shift.
    @ObservationIgnored private var downNow = Set<MacroRecording.Control>()
    /// The recording is full when this many steps remain that the path
    /// thinning cannot drop; a gliding move (one another move follows)
    /// gives way to a later press instead, so it does not count.
    var isFull: Bool {
        // A press still down becomes a Release step when the take closes it,
        // so it counts only past the room: counted at it, the take stopped
        // on the last press and dropped it (a row at 199 recorded nothing).
        let completed = liveSteps().filter { !($0.eventKind == .moveTo && $0.holdMs > 0) }.count
        return completed >= room || completed + downNow.count > room
    }
    /// Steps the row can still take; a take stops there rather than being
    /// cut when it lands. Set as the sheet opens.
    var room = MacroRecording.maxSteps

    /// The recording's steps, worked out once per change of the recording
    /// and per timing choice: isFull after every edge and the sheet's body
    /// each ran steps() over the whole take again.
    func liveSteps(keepTiming: Bool = true, capWaitMs: Int? = nil) -> [MacroStep] {
        // The recording itself is not tracked: a body that shows the steps
        // re-runs when their count or content changes, read here.
        _ = (liveStepCount, liveStepsRevision)
        let key = StepsKey(keepTiming: keepTiming, capWaitMs: capWaitMs)
        if let known = stepsCache[key] { return known }
        let steps = recording.steps(keepTiming: keepTiming, capWaitMs: capWaitMs)
        stepsCache[key] = steps
        return steps
    }
    private struct StepsKey: Hashable {
        var keepTiming: Bool
        var capWaitMs: Int?
    }
    @ObservationIgnored private var stepsCache: [StepsKey: [MacroStep]] = [:]
    /// The steps last published, to tell a change of them from none.
    @ObservationIgnored private var publishedSteps: [MacroStep] = []
    @ObservationIgnored private var livePublishQueued = false

    private func recordingChanged() {
        stepsCache.removeAll(keepingCapacity: true)
        if hasEdges == recording.isEmpty { hasEdges = !recording.isEmpty }
        guard !livePublishQueued else { return }
        livePublishQueued = true
        // Once per turn of the main queue: the emergency stop puts the
        // edges back one at a time.
        DispatchQueue.main.async { [weak self] in self?.publishLive() }
    }

    /// Publishes the steps' count, or a revision when the steps changed
    /// and their count did not; nothing when they are the same. Any timing
    /// choice follows from the default steps: they carry every wait, hold
    /// and glide the others round or cap.
    private func publishLive() {
        livePublishQueued = false
        let steps = liveSteps()
        if steps.count != liveStepCount {
            liveStepCount = steps.count
        } else if !Self.sameSteps(steps, publishedSteps) {
            liveStepsRevision &+= 1
        }
        publishedSteps = steps
    }

    /// The same steps, ids aside: steps() makes new ids on every call.
    /// Every stored field but the id; a field added to MacroStep goes here.
    nonisolated static func sameSteps(_ a: [MacroStep], _ b: [MacroStep]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.delayMs == y.delayMs && x.holdMs == y.holdMs && x.eventKind == y.eventKind
                && x.modifiers == y.modifiers && x.count == y.count && x.watchID == y.watchID
                && x.timeoutMs == y.timeoutMs && x.continueOnTimeout == y.continueOnTimeout
                && sameAction(x.action, y.action)
        }
    }

    /// Two actions alike in every field but their id: each run of steps()
    /// makes actions with fresh ids, so `==` called every edge a change and
    /// the recorder published on every pointer sample.
    nonisolated static func sameAction(_ a: OutputAction, _ b: OutputAction) -> Bool {
        let fa = Mirror(reflecting: a).children, fb = Mirror(reflecting: b).children
        guard fa.count == fb.count else { return false }
        for (x, y) in zip(fa, fb) where x.label != "id" {
            guard x.label == y.label, String(describing: x.value) == String(describing: y.value) else { return false }
        }
        return true
    }

    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private var trustSubscription: AnyCancellable?
    @ObservationIgnored private var activation: [NSObjectProtocol] = []
    @ObservationIgnored private var stopTimer: Timer?
    /// A recording nobody stops ends on its own.
    static let longestSeconds: TimeInterval = 300
    private static let reason = "macroRecorder"

    private init() {}

    var accessibilityGranted: Bool { ExternalInputDeviceService.shared.accessibilityGranted }

    /// Set when recording resumes with edges already kept: the first new
    /// edge lands 50 ms after the last old one instead of a real gap later.
    @ObservationIgnored private var pendingResume = false
    @ObservationIgnored private var timeShift: Double = 0

    func start() {
        guard !isRecording else { return }
        pendingResume = !recording.isEmpty
        if !pendingResume { timeShift = 0 }
        // Timestamps from the last take sit on its clock: an Escape there
        // must not pair with the first one here.
        lastEscapeAt = -1
        lastPathSampleAt = -1
        pressPoints.removeAll()
        downNow.removeAll()
        awaitingFirstClick = skipFirstClick
        isRecording = true
        paused = NSApp.isActive
        // Step aside so the app the macro is for comes forward on its own:
        // clicking it to switch was the click that ended up as step one.
        // After the Start button's own click has finished.
        userPaused = false
        RecordingHUD.shared.show()
        if NSApp.isActive {
            hidForRecording = true
            DispatchQueue.main.async { NSApp.hide(nil) }
        } else {
            resumedAt = ProcessInfo.processInfo.systemUptime
        }
        let service = ExternalInputDeviceService.shared
        service.retain(Self.reason, mouse: true, keyboard: true, movement: recordPointerPath)
        subscription = service.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.ingest(event) }
        // Accessibility taken away: the monitors go with it, so the take
        // ends here with a reason instead of saying "recording" until the
        // timer, and does not pick up mid take when the permission is back.
        trustSubscription = AccessibilityPermissionService.shared.$isTrusted
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trusted in
                guard let self, !trusted, self.isRecording else { return }
                ActivityLog.shared.error("Macro", "Recording stopped: Accessibility access was taken away")
                // Back to the front: hidden for the take, the app stayed
                // hidden with the recording sheet open and no Dock icon.
                self.stop(returnToApp: true)
            }
        let center = NotificationCenter.default
        activation = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.paused = true
                    // The click on the Dock icon that brought InputConfig
                    // back arrived whole before the activation: not a step.
                    let now = ProcessInfo.processInfo.systemUptime - self.timeShift
                    if self.recording.dropTrailingClick(before: now, within: 0.3) {
                        self.pressCount = max(0, self.pressCount - 1)
                    }
                    // A click on InputConfig's window, or the Command Tab that
                    // brought it, is still down here: not a step either.
                    let dropped = self.recording.dropReturnToApp()
                    self.pressCount = max(0, self.pressCount - dropped)
                    self.downNow = self.downNow.filter { control in
                        self.recording.edges.last(where: { $0.control == control })?.down == true
                    }
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.paused = false
                    self.closeReleased()
                    // The click that switches away is already dropped by
                    // resumedAt; re-arming Skip the first click here lost
                    // the first real click after every trip to InputConfig.
                    self.resumedAt = ProcessInfo.processInfo.systemUptime
                }
            },
        ]
        let timer = Timer(timeInterval: Self.longestSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(returnToApp: true) }
        }
        stopTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        ActivityLog.shared.info("Macro", "Recording keys and mouse buttons")
    }

    /// `returnToApp`: the take ended in the other app (Escape twice, the
    /// time limit, a full recording), so InputConfig comes back to show
    /// the steps.
    func stop(returnToApp: Bool = false) {
        guard isRecording else { return }
        isRecording = false
        paused = false
        userPaused = false
        RecordingHUD.shared.hide()
        // A pad that connected during the take is looked at now.
        ControllerConnectWatcher.shared.recheck()
        FrontmostAppWatcher.shared.recheck()
        if hidForRecording {
            hidForRecording = false
            if returnToApp, !NSApp.isActive {
                NSApp.unhide(nil)
                NSApp.activate()
            }
        }
        // The switch back (Command Tab, a click on the window) is not a
        // step, and Record More would append after it.
        pressCount = max(0, pressCount - recording.dropReturnToApp())
        if !downNow.isEmpty {
            recording.closeOpen(downNow)
            downNow.removeAll()
        }
        subscription = nil
        trustSubscription = nil
        for token in activation { NotificationCenter.default.removeObserver(token) }
        activation.removeAll()
        stopTimer?.invalidate()
        stopTimer = nil
        ExternalInputDeviceService.shared.release(Self.reason)
        ActivityLog.shared.info("Macro", "Recording stopped: \(liveSteps().count) steps")
    }

    /// The emergency stop: a recording is not an output, but "everything
    /// stopped" covers it. The chord's Control, Option and Command arrived
    /// as edges (the period never does; the hot key takes it) and their
    /// releases will not, so the modifier edges at the end, which cover
    /// no key, go first and the recording is as it was before the chord.
    func stopForEmergencyStop() {
        guard isRecording else { return }
        let edges = recording.edges
        var end = edges.count
        while end > 0, edges[end - 1].control.isModifier { end -= 1 }
        if end < edges.count {
            let droppedPresses = edges[end...].filter(\.down).count
            recording.removeAll()
            for edge in edges[..<end] { recording.add(edge.control, down: edge.down, at: edge.at) }
            pressCount = max(0, pressCount - droppedPresses)
        }
        stop(returnToApp: true)
        ActivityLog.shared.info("Macro", "Recording stopped by the emergency stop")
    }

    /// Forget what was recorded; recording goes on if it was.
    /// The recording panel's Pause and Resume. The pause is cut out: the
    /// first press after Resume lands 50 ms after the last one.
    func togglePause() {
        guard isRecording else { return }
        userPaused.toggle()
        pausedEscapeAt = -1
        if userPaused {
            recording.dropTrailingMoves()
        } else {
            closeReleased()
            if !recording.isEmpty { pendingResume = true }
        }
    }

    /// A release made while nothing was recorded (Pause, InputConfig in
    /// front) was lost, and the press then spanned every step up to its
    /// next release: the Hold down wrapped all of them.
    private func closeReleased() {
        let gone = downNow.filter { control in
            switch control {
            case .key(let code):
                // A key with no name is stored as its key code past the
                // base. One with no code at all (fn, the media keys) cannot
                // be asked, so it stays open as a side button does.
                guard let vk = KeyCodeMap.hidToVirtualKeyCode[code]
                        ?? ((KeyCodeMap.unknownKeyBase..<KeyCodeMap.unknownSystemKeyBase).contains(code)
                            ? code - KeyCodeMap.unknownKeyBase : nil) else { return false }
                return !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(vk))
            case .mouseButton(let button):
                // The hardware state names three buttons only: a side
                // button was judged by the middle one. Left open, it closes
                // with the take.
                guard (0...2).contains(button), let which = CGMouseButton(rawValue: UInt32(button)) else { return false }
                return !CGEventSource.buttonState(.hidSystemState, button: which)
            default:
                return true
            }
        }
        guard !gone.isEmpty, let last = recording.edges.last?.at else { return }
        for control in gone.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            recording.add(control, down: false, at: last + 0.001)
        }
        downNow.subtract(gone)
    }

    func startOver() {
        recording.removeAll()
        pressCount = 0
        pendingResume = false
        timeShift = 0
        lastEscapeAt = -1
        lastPathSampleAt = -1
        pressPoints.removeAll()
        downNow.removeAll()
    }

    /// Where the pointer is, in CoreGraphics coordinates (origin at the
    /// top left of the primary display), as placePointer expects.
    static func pointerCG() -> (x: Double, y: Double) {
        let loc = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return (Double(loc.x).rounded(), Double(height - loc.y).rounded())
    }

    /// F10, F11 and F12 are Mute, Volume Down and Volume Up on an Apple
    /// keyboard's top row unless fn is held, so as stop keys they answer
    /// to those keys as well.
    static func isStopKey(_ code: Int, stopKey: Int) -> Bool {
        stopKey >= 0 && (code == stopKey || (stopKey == 67 && code == 310)
                         || (stopKey == 68 && code == 312) || (stopKey == 69 && code == 311))
    }

    /// Skip the first click, or a click arriving just after the switch.
    static func firstClickSkipped(awaiting: Bool, sinceSwitch: Double?) -> Bool {
        awaiting || (sinceSwitch.map { $0 < 0.4 } ?? false)
    }

    /// The stop key and Escape twice end a paused take too: neither is ever
    /// a step, and the sheet says either one stops it.
    private func stopWhilePaused(_ event: ExternalInputDeviceService.Event) {
        guard case .keyDown(_, let code) = event else { return }
        if Self.isStopKey(code, stopKey: stopKeyCode) {
            stop(returnToApp: true)
        } else if code == 41 {
            let now = ProcessInfo.processInfo.systemUptime
            if now - pausedEscapeAt <= Self.doubleEscapeSeconds {
                pausedEscapeAt = -1
                stop(returnToApp: true)
            } else {
                pausedEscapeAt = now
            }
        }
    }

    private func ingest(_ event: ExternalInputDeviceService.Event) {
        guard isRecording, !paused else { return }
        if userPaused {
            stopWhilePaused(event)
            return
        }
        // Only an event that becomes an edge may take the resume shift.
        switch event {
        case .keyDown:
            // Typing first: the window in front was already the right one.
            awaitingFirstClick = false
        case .mouseButtonDown:
            // A click on the recording panel (Pause, Stop, a drag) is not a
            // step; its release is dropped with it.
            if RecordingHUD.shared.contains(NSEvent.mouseLocation) { return }
            // The click that picked the window, or the one that switched
            // apps arriving a moment after the switch: not a step. Its
            // release is dropped below, as its press was never recorded.
            let sinceSwitch = resumedAt >= 0 ? ProcessInfo.processInfo.systemUptime - resumedAt : nil
            if Self.firstClickSkipped(awaiting: awaitingFirstClick, sinceSwitch: sinceSwitch) {
                awaitingFirstClick = false
                return
            }
        case .keyUp(_, let code):
            guard downNow.contains(.key(code)) else { return }
        case .mouseButtonUp(_, let button):
            guard downNow.contains(.mouseButton(button)) else { return }
        case .mouseMove:
            // After Resume the pointer is on its way back from the panel:
            // the path starts again with the next press.
            guard recordPointerPath, !pendingResume else { return }
        case .scroll(_, let dx, let dy):
            guard recordScrolling, dx != 0 || dy != 0 else { return }
        default:
            return
        }
        var now = ProcessInfo.processInfo.systemUptime
        if pendingResume {
            pendingResume = false
            if let last = recording.edges.last?.at { timeShift = now - last - 0.05 }
            // An Escape from before the pause and one after it are no double
            // Escape: paired, they stopped the take and deleted the first.
            lastEscapeAt = -1
            lastPathSampleAt = -1
        }
        now -= timeShift
        switch event {
        case .keyDown(_, let code):
            // The stop key: never a step, and its release is dropped too.
            if Self.isStopKey(code, stopKey: stopKeyCode) {
                stop(returnToApp: true)
                return
            }
            // Escape twice: stop, and neither Escape is a step.
            if code == 41 {
                if now - lastEscapeAt <= Self.doubleEscapeSeconds {
                    recording.dropTrailingEscapes(since: lastEscapeAt)
                    pressCount = max(0, pressCount - 1)
                    lastEscapeAt = -1
                    stop(returnToApp: true)
                    return
                }
                lastEscapeAt = now
            }
            recording.add(.key(code), down: true, at: now)
            downNow.insert(.key(code))
            pressCount += 1
        case .keyUp(_, let code):
            downNow.remove(.key(code))
            recording.add(.key(code), down: false, at: now)
        case .mouseButtonDown(_, let button):
            let p = Self.pointerCG()
            pressPoints[button] = p
            if recordClickPositions {
                recording.add(.move(x: p.x, y: p.y), down: true, at: now - 0.0001)
            }
            recording.add(.mouseButton(button), down: true, at: now)
            downNow.insert(.mouseButton(button))
            pressCount += 1
        case .mouseMove:
            guard recordPointerPath, now - lastPathSampleAt >= 0.1 else { return }
            lastPathSampleAt = now
            let p = Self.pointerCG()
            recording.add(.move(x: p.x, y: p.y), down: true, at: now)
        case .scroll(_, let dx, let dy):
            guard recordScrolling else { return }
            if dy != 0 { recording.add(.scroll(axis: .vertical, lines: dy), down: true, at: now) }
            if dx != 0 { recording.add(.scroll(axis: .horizontal, lines: dx), down: true, at: now) }
        case .mouseButtonUp(_, let button):
            // Let go somewhere else: the move inside the press makes it a
            // drag (Hold down, Move pointer, Release) when played.
            if recordClickPositions, let start = pressPoints.removeValue(forKey: button) {
                let p = Self.pointerCG()
                if abs(p.x - start.x) >= 3 || abs(p.y - start.y) >= 3 {
                    recording.add(.move(x: p.x, y: p.y), down: true, at: now - 0.0001)
                }
            }
            downNow.remove(.mouseButton(button))
            recording.add(.mouseButton(button), down: false, at: now)
        default:
            // Pointer movement, scrolling, pressure and pens are not steps.
            break
        }
        // Full: no further press would fit.
        if isFull { stop(returnToApp: true) }
    }
}
