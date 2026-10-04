import Foundation
import Combine
import AppKit
import GameController

/// The core engine that reads controller inputs and fires output actions.
/// 120Hz polling with debug logging capability.
@MainActor
class MappingEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var activePreset: Preset?

    /// Non-published copies of exactly what the 120 Hz poll loop reads.
    ///
    /// `pollControllers` used to start with `guard let preset = activePreset`,
    /// which goes through the @Published getter and re-materializes the whole
    /// Preset - every JoystickMapping, BindingModel and OutputAction - on
    /// EVERY tick. That showed up in a profile as `initializeWithCopy for
    /// BindingModel` / `OutputAction` and as time inside
    /// `activePreset.getter`. These are refreshed only when the preset
    /// actually changes.
    private var pollJoysticks: [JoystickMapping] = []
    private var pollDriveConfig: DriveConfig?
    /// Effective poll rate of the active timer in Hz. Driven by
    /// `installPollTimer()` so the UI (DebugLogView footer, Settings
    /// readout) always shows the *actual* rate, not the saved
    /// default. 120 is the same default we apply in installPollTimer
    /// when no setting is saved yet.
    @Published var currentPollHz: Int = 120
    /// Adaptive polling. A preset that reads only controller buttons, sticks
    /// and the D-pad drops to `idlePollHz` after `idleAfter` seconds with
    /// nothing pressed, held or moving, and any input brings it straight
    /// back: GameController's change callback wakes it at once, and the
    /// slower poll sees every other change itself. Polling a still
    /// controller 120 times a second was most of what the app cost while it
    /// sat in the background with a preset on.
    private var idlePolling = false
    private var idleEligible = false
    /// The running preset's "D-pad: one direction at a time", and which axis
    /// of each D-pad went down first (1 across, 2 up and down), keyed by
    /// group times 16 plus the hat index.
    private var dpadOneWay = false
    private var dpadHeldAxis: [Int: UInt8] = [:]
    private var lastInputChangeAt: CFTimeInterval = 0
    private static let idlePollHz = 30
    private static let idleAfter: CFTimeInterval = 2.0
    /// Mirror of currently-active inputs. NOT @Published - observers update
    /// via the throttled `activeInputsPublished` instead so a fast-changing
    /// joystick does not re-render the editor 120 times per second.
    var activeInputs: Set<String> = []
    /// Not published here on purpose: see LiveInputStore. Mirrored there
    /// at the same 10 Hz cadence, so the editor rows still light without
    /// the whole window re-rendering.
    var activeInputsPublished: Set<String> = [] {
        didSet { LiveInputStore.shared.active = activeInputsPublished }
    }
    private var activeInputsLastFlush: CFTimeInterval = -.infinity
    @Published var debugLog: [(text: String, joystickIndex: Int?)] = []  // Rolling debug log visible in UI

    private var controllerService: GameControllerService
    /// For Settings' reload after Reset or Restore.
    var controllerServiceForSettings: GameControllerService { controllerService }
    private var pollTimer: Timer?

    /// Subscription to `ExternalInputDeviceService.events`. Established in
    /// `start()` and canceled in `stop()` so the engine only listens to
    /// keyboards / mice while a preset is active.
    private var externalEventSubscription: AnyCancellable?
    /// Tracks the last seen power-source label so we can re-install
    /// the poll timer only when the user actually plugs / unplugs.
    /// Without this gate the @Published source string would trigger an
    /// applyPollRate on every IOPS refresh tick (every 5 s).
    private var powerSourceSubscription: AnyCancellable?
    /// True while this engine holds a SystemStatsService retain.
    private var holdsSystemStats = false
    private var controllerListSubscription: AnyCancellable?
    private var rawSlotSubscription: AnyCancellable?
    private var steamSlotSubscription: AnyCancellable?
    /// Which controller object held each slot at the last check, so a
    /// different pad taking a slot resets that slot's held state.
    private var slotOccupants: [Int: String] = [:]
    private var lastSeenPowerSource: String?

    /// Per-device map of currently-held HID keyboard usages. Updated by the
    /// IOHIDManager callback in `ExternalInputDeviceService`; read by the
    /// 120 Hz poll loop the same way it reads controller state.
    private var externalKeysDown: [String: Set<Int>] = [:]
    /// Per-device map of currently-held mouse button indices.
    private var externalMouseButtonsDown: [String: Set<Int>] = [:]
    /// Accumulated mouse motion deltas since the last poll frame, per device.
    /// Reset to zero at the start of every poll frame.
    private var externalMouseDX: [String: Int] = [:]
    private var externalMouseDY: [String: Int] = [:]
    /// Accumulated scroll wheel ticks since the last poll frame, per device.
    private var externalScrollDX: [String: Int] = [:]
    private var externalScrollDY: [String: Int] = [:]

    private var activeStates: [Int: Set<String>] = [:]
    private let defaultAxisThreshold: Float = 0.25
    /// The smallest per-frame touchpad move a row counts, as a fraction of
    /// the pad: just under one native step on every pad. A PlayStation step
    /// is 1/1919 (0.00052); a Steam Controller's sideways step is scaled by
    /// 1080/1920 (0.00029), and at 0.0005 every slow horizontal slide on it
    /// was dropped.
    private static let touchpadMotionThreshold: Float = 0.00025
    private let hatThreshold: Float = 0.5

    // Toggle mode state: tracks which bindings are currently toggled on
    private var toggleStates: [String: Bool] = [:]
    /// Presses fired so far in the current turbo run, per binding, for the
    /// auto-click "stop after N presses" setting.
    private var turboCounts: [String: Int] = [:]
    /// The controller slot whose bindings are being evaluated right now, so
    /// an app action fired from a button can act on that controller.
    private var pollingJoystickIndex: Int = 0
    /// Group index to the controller slot it reads; see `effectiveSlot`.
    private var slotForGroup: [Int: Int] = [:]
    /// A group of the preset reads a raw HID pad or the Steam Controller.
    private var readsDirectPad: Bool {
        let read = Set(slotForGroup.values)
        return controllerService.rawHIDGamepadSlots.keys.contains { read.contains($0) }
            || controllerService.steamControllerSlot.map { read.contains($0) } ?? false
    }
    /// Groups that read the touchpad feed's controller; nil lets every group.
    /// TouchpadService tracks one surface, so a second player's touchpad
    /// rows fired from the first player's pad.
    private var touchpadGroups: Set<Int>?
    /// The same for the second surface (a Steam Controller's left pad).
    private var secondTouchGroups: Set<Int>?
    /// The same for the Steam right-pad surface.
    private var steamTouchGroups: Set<Int>?

    /// Whether the group being polled reads a Steam Controller.
    private var pollingSteamGroup: Bool {
        controllerService.isSteamSlot(slotForGroup[pollingJoystickIndex] ?? pollingJoystickIndex)
    }

    /// The touch surface a row on the group being polled reads.
    private func touchService(_ surface: Int?) -> TouchpadService {
        TouchpadService.forSurface(surface, steam: pollingSteamGroup)
    }

    /// The groups allowed to read that surface, nil for any.
    private func touchGate(_ surface: Int?) -> Set<Int>? {
        if surface == 1 { return secondTouchGroups }
        return pollingSteamGroup ? steamTouchGroups : touchpadGroups
    }

    /// Tilt pointing (position control). The pointer's offset is a function
    /// of the controller's absolute tilt: offset = gain x (angle - angle at
    /// anchor). Point up, slam down to flat, and the pointer is back on the
    /// anchor because the anchor is an angle, not a sum of steps. This is how
    /// console pointer modes work (Wii, Switch); a relative gyro-as-mouse
    /// cannot promise it. Re-anchored on start, re-zero and Center Pointer.
    /// The state and its filter live in `TiltPointer`.
    /// Keyed by group and tilt channel (pitch on gyro X, roll on gyro Y).
    private var pitchAnchors: [Int: TiltPointer] = [:]
    /// Set to drop every anchor. Taken up only on a later poll than the one
    /// that asked (`pitchAnchorResetPoll`): a re-zero pressed on the
    /// controller fires in the middle of a poll whose state was read before
    /// the re-zero touched the tilt estimate, and anchoring on that stale
    /// state put the whole difference onto the pointer one poll later, a
    /// jump away from the center it had just been put on.
    private var pitchAnchorReset = true {
        didSet { if pitchAnchorReset { pitchAnchorResetPoll = pollCount } }
    }
    private var pitchAnchorResetPoll = 0
    private func anchorKey(_ group: Int, _ channel: MotionChannel) -> Int { group &* 16 &+ channelIndex(channel) }

    /// A re-center in progress: where the pointer was put, and when. Motion
    /// rows send nothing until it is confirmed, then anchor on fresh state.
    private var motionRecenter: (point: CGPoint, poll: Int, at: CFTimeInterval)?

    /// Make the controller's current tilt the pointer's new neutral, with
    /// the pointer at the center of the display it is on (every re-zero, the
    /// Center Pointer action). Only while a preset is moving the pointer from
    /// motion (in the editor too, where the pointer keeps working); with
    /// none, a re-zero leaves the pointer alone.
    func reanchorMotion() {
        pitchAnchorReset = true
        guard isRunning, !outputsBlocked || pointerOnly, let preset = activePreset,
              preset.joysticks.contains(where: { group in
                  group.bindings.contains { $0.input.type == .motion && Self.drivesPointer($0) }
              }) else { return }
        // Whatever this poll's motion rows already added is dropped, so it
        // does not land after the warp.
        pendingMotionDeltaX = 0
        pendingMotionDeltaY = 0
        guard let center = InputSimulator.shared.centerPointerOnCurrentScreen() else { return }
        motionRecenter = (center, pollCount, CACurrentMediaTime())
    }

    /// Called at the top of every poll. The pointer pump may still be paying
    /// out the motion of the poll before the re-center (it spreads each
    /// poll's movement over the next few milliseconds), which nudged the
    /// pointer off the center it was just put on. Once that has run out (two
    /// polls and 40 ms), the pointer is put back on the same center and the
    /// motion rows anchor from there.
    private func confirmMotionRecenter() {
        guard let pending = motionRecenter else { return }
        pitchAnchorReset = true
        guard pollCount >= pending.poll + 2, CACurrentMediaTime() - pending.at >= 0.04 else { return }
        InputSimulator.shared.warpPointer(to: pending.point)
        motionRecenter = nil
    }

    /// Radians of tilt offset not yet sent to the pointer for this group,
    /// smoothed (see `TiltPointer`), or nil when the controller has no
    /// absolute tilt. Positive = nose up (or right side down) relative to
    /// the anchor. Zero while a re-anchor waits for fresh state.
    private func pendingTilt(group: Int, channel: MotionChannel, state: ControllerState,
                             deadzone: Float? = nil) -> Float? {
        guard let absolute = state.motionAbsolute[channel] else { return nil }
        if pitchAnchorReset {
            guard pollCount > pitchAnchorResetPoll, motionRecenter == nil else { return 0 }
            pitchAnchors = [:]
            pitchAnchorReset = false
        }
        let key = anchorKey(group, channel)
        var entry = pitchAnchors[key] ?? TiltPointer(anchor: absolute)
        // Once per poll per channel, however many rows read it.
        if entry.updatedPoll != pollCount {
            entry.update(absolute: absolute, dt: frameScale / 120,
                         deadzone: deadzone ?? TiltPointer.defaultDeadzone)
            entry.updatedPoll = pollCount
        }
        pitchAnchors[key] = entry
        return entry.owed
    }
    private var slotResolveTick = 0
    private var loggedSlotRedirect: [Int: Int] = [:]
    /// Fader engagement per absolute-volume binding: resting position at
    /// activation, and whether the user has moved the control since.
    private var faderBaseline: [UUID: Float] = [:]
    private var faderEngaged: Set<UUID> = []
    // Turbo state: tracks last fire time for turbo bindings
    /// Last fire time per turbo binding, expressed as CACurrentMediaTime
    /// seconds (monotonic, allocation-free). Was previously [String: Date]
    /// which forced a fresh Date() allocation on every turbo poll.
    private var turboTimestamps: [String: CFTimeInterval] = [:]
    /// bindKeys whose macro chain is currently executing. Used to
    /// suppress a fresh executeMacro() call on a re-press while the
    /// previous chain is still running, preventing parallel macro
    /// threads that doubled outputs.
    private var macrosInFlight: Set<String> = []
    /// The newest chain started on each row. Pauses and locks clear
    /// `macrosInFlight` while chains still run, so an older chain's finish
    /// cleared the flag of a newer one and a third press ran two at once.
    private var macroChainToken: [String: Int] = [:]
    private var macroChainCounter = 0
    /// Rows whose current press began inside their double-tap window.
    private var secondTapPressed: Set<String> = []
    /// Rows with an app action whose control has been seen up since the
    /// preset started; cleared on every start.
    private var armedAppActionRows: Set<String> = []
    /// After a preset starts and after a Scan starts or ends in the editor,
    /// a row whose control is already down waits for it to come up before
    /// it can fire: a click held through an auto-switch came back as the
    /// second half of a double click, and a scanned toggle or tap-hold row
    /// started clicking inside the editor. Rows seen up since then:
    private var rowsSeenUp: Set<String> = []
    private var requireSeenUp = false
    private var heldRowBlockedThisPoll = false
    private var lastPointerWhileEditing = false

    /// Pointer motion and scrolling from a held stick carry on through
    /// those edges; they have no press to repeat.
    private static func waitsForRelease(_ binding: BindingModel) -> Bool {
        guard binding.holdOutputs == nil, binding.doubleTapOutputs == nil, binding.macroSteps == nil,
              binding.toggleMode != true, binding.turboEnabled != true, !binding.outputs.isEmpty else { return true }
        return !binding.outputs.allSatisfy { $0.type == .mouseMotion || $0.type == .mouseWheel }
    }

    /// Starts the wait above for every row.
    private func holdBackHeldRows() {
        rowsSeenUp.removeAll()
        requireSeenUp = true
    }
    private var appActionRowCache: [UUID: Bool] = [:]
    private func appActionRow(_ binding: BindingModel) -> Bool {
        if let known = appActionRowCache[binding.id] { return known }
        let all = binding.outputs + (binding.holdOutputs ?? []) + (binding.doubleTapOutputs ?? [])
            + (binding.macroSteps ?? []).map(\.action)
        let has = all.contains { $0.type == .appAction }
        appActionRowCache[binding.id] = has
        return has
    }
    // Cache of serialized input keys to avoid repeated string allocations at 120Hz
    private var serializedKeyCache: [UUID: String] = [:]
    /// Cache for the toggle/turbo/macro bind key ("slot:uuid") so a preset with
    /// those bindings doesn't rebuild binding.id.uuidString every 120 Hz frame.
    private var bindKeyCache: [UUID: String] = [:]

    /// Monotonically increasing counter bumped on every start()/stop().
    /// Background blocks (macros, turbo release) capture this at schedule
    /// time and bail before re-entering the engine when the value has
    /// changed - prevents stuck keys after stop() invalidates the poll
    /// timer but in-flight macro / turbo blocks still try to release a
    /// key from a preset that's no longer active.
    private var engineGeneration: Int = 0

    /// Scratch Sets reused across poll frames so the 120 Hz hot path
    /// doesn't allocate a fresh `Set<String>` per joystick per tick.
    /// At 120 Hz × 4 joysticks × small bindings each, the old code
    /// burned ~3,840 Set allocations / sec just on highlight
    /// bookkeeping. `removeAll(keepingCapacity:)` keeps the hash
    /// table allocated and just zeroes the count.
    private var scratchActiveSet: Set<String> = []
    /// Press edges per row (by bindKey), so two rows on one input each get
    /// their own press: a second row with a higher deadzone, or a flick row
    /// beside a gyro pointer row, never pressed while edges were shared by
    /// input. `activeStates` (by input) stays for highlighting and idling.
    private var rowActiveStates: [Int: Set<String>] = [:]
    private var scratchRowActiveSet: Set<String> = []
    /// Emergency stop: when the panic button was first seen held, per slot.
    /// nil means it is not currently down anywhere.
    private var panicHoldStart: TimeInterval?

    /// Chords: plain input keys claimed this frame by a satisfied chord row
    /// on the slot being polled, so the plain row on the same input stays quiet.
    private var chordClaimed: Set<String> = []
    /// The held-control sets of the chords satisfied this frame, by input,
    /// so a chord with more held controls takes over from one with fewer.
    private var chordSatisfied: [String: [Set<String>]] = [:]
    /// Plain inputs a chord used, per group, kept quiet until they are let
    /// go. Letting go of LB before A in an LB+A chord used to fire A's plain
    /// row on the way out.
    private var chordLatched: [Int: Set<String>] = [:]
    private var chordKeyCache: [UUID: String] = [:]
    /// Gyro ratchet: true while a "Pause Motion While Held" row on the slot
    /// being polled is held. Motion bindings read 0 for the frame.
    private var currentSlotMotionMuted = false
    /// True while evaluating a binding that was active last frame, so an
    /// axis releases at 90% of its threshold instead of chattering at the
    /// deadzone edge.
    private var hysteresisActive = false
    private var scratchAllActiveSet: Set<String> = []

    /// Follows the "show developer activity log" setting. This used to be
    /// hard-wired to true with no setter, so every press and release built a
    /// log string and the 5 Hz published log flush invalidated the root view
    /// in shipping builds, for a panel almost nobody has open.
    private var debugEnabled = false
    private var debugSettingObserver: NSObjectProtocol?
    private static let debugLogDefaultsKey = "InputConfig.showDebugLog"
    private var debugLineCount = 0

    /// Internal buffer the polling loop writes to without triggering UI
    /// re-renders. A separate timer flushes this into `debugLog` (which is
    /// @Published) at a much slower rate so the editor and other observers
    /// of `mappingEngine` do not re-render on every input event.
    private var pendingLog: [(text: String, joystickIndex: Int?)] = []
    /// Set when `pendingLog` gains a new entry. Lets flushPendingLog skip the
    /// @Published mirror assignment on idle 5 Hz ticks, so DebugLogView does
    /// not re-render and re-filter the whole log when nothing has changed.
    private var pendingLogDirty = false
    private var logFlushTimer: Timer?
    /// True while the active preset retains TouchpadService. Tracked
    /// separately so stop() only releases when start() retained.
    private var usesTouchpadInput = false
    /// Mirrors usesTouchpadInput for cursor-region presets: tracks
    /// whether we asked CursorRegionService to poll the cursor, so
    /// stop() balances the beginTracking() call exactly once.
    private var usesCursorRegionInput = false

    /// When true, the engine keeps polling and updating `activeInputs` so the
    /// editor's row highlights and the touchpad calibration UI keep working,
    /// but it does NOT fire any outputs (no mouse motion, no keystrokes, no
    /// MIDI). Set while the preset editor is open so a touchpad-as-mouse
    /// preset can't fling the cursor across the screen while the user is
    /// trying to configure it.
    @Published var outputsPaused: Bool = false {
        didSet {
            // Re-rate the poll loop for the new state. Dropping from 120 Hz to
            // 15 Hz while the editor is open is what stops the timer competing
            // with scrolling.
            // Back to the full rate on either edge: an idle 30 Hz carried
            // into the editor sampled the passthrough pointer every 33 ms.
            if oldValue != outputsPaused, isRunning { idlePolling = false; installPollTimer() }
            // Tilt made while paused is not owed to the pointer on resume.
            if oldValue != outputsPaused { pitchAnchorReset = true }
            if outputsPaused {
                // Release any output state that was currently held so the
                // user doesn't end up with a stuck key or held mouse button
                // the moment we pause.
                driveProcessor.releaseAll()
                InputSimulator.shared.releaseAll()
                MIDIService.shared.releaseAllNotes()
                releaseHeldLights()
                // Clear the logical toggle bookkeeping too. The physical outputs
                // were just released, so leaving toggleStates marked "on" would
                // desync them: an un-pause would not re-press a held toggle, and
                // the next press would immediately toggle it back off.
                toggleStates.removeAll()
                MouseMotionPump.shared.setVelocity(x: 0, y: 0)
                MouseMotionPump.shared.setScrollVelocity(x: 0, y: 0)
                pendingMouseDeltaX = 0
                pendingMouseDeltaY = 0
                pendingMotionDeltaX = 0
                pendingMotionDeltaY = 0
                mouseCarryX = 0
                mouseCarryY = 0
                pendingScrollDeltaX = 0
                pendingScrollDeltaY = 0
            }
            if oldValue && !outputsPaused {
                // The pointer rows could act while the editor was open (a
                // grab toggle, a hold click); let go of what they hold, since
                // the latches that would release it are cleared below.
                driveProcessor.releaseAll()
                InputSimulator.shared.releaseAll()
                MouseMotionPump.shared.setVelocity(x: 0, y: 0)
                MouseMotionPump.shared.setScrollVelocity(x: 0, y: 0)
            }
            // Paused (from the menu bar, or the editor over a preset whose
            // pointer does not pass through), the Steam Controller gets its
            // own mouse and keys back, since the preset sends nothing.
            if oldValue != outputsPaused, isRunning {
                SteamControllerService.shared.setLizardModeOff(!outputsPaused || editorPassthroughApplies)
            }
            if oldValue != outputsPaused {
                // Presses made while paused still ran the latch logic, so a
                // toggle turbo row came back as a running auto-clicker and a
                // plain toggle sent a bare key-up on its next press. Clear
                // the latches on both edges; nothing was sent while paused.
                // Running macro, turbo and repeat chains stop with them.
                engineGeneration &+= 1
                clearLatches()
                ExternalInputDeviceService.shared.setBlockingPaused(outputsBlocked)
                // Recenter, confine and hide pause with everything else:
                // they kept pulling the pointer to the middle while Pause
                // Outputs was on and over the open editor's Save button.
                CursorGuardService.shared.setSuspended(outputsBlocked)
            }
        }
    }

    /// Observes PresetStore saves so the running engine follows edits.
    private var presetSaveObserver: NSObjectProtocol?

    /// Re-arm on the edited preset when it is the one currently running.
    /// `start(with:)` already calls `stop()` first, so this is a clean
    /// restart rather than a merge.
    func activePresetWasEdited(_ updated: Preset) {
        guard isRunning, activePreset?.id == updated.id else { return }
        reload(with: updated)
    }

    /// Follow an edit to the running preset. Not an activation: no
    /// auto-launch, no review-prompt count, no "Started" line, no stats
    /// bump. Every save used to run a full start, so typing an 8-letter
    /// name counted 8 activations and opened the auto-launch URL 8 times.
    /// A change only to the name, tag, notes, or order does nothing at all,
    /// and a preset edited down to no rows and no drive stops.
    func reload(with updated: Preset) {
        guard isRunning, let current = activePreset, current.id == updated.id else { return }
        if Self.runtimeShape(of: current) == Self.runtimeShape(of: updated) {
            activePreset = updated   // keep the displayed name current
            return
        }
        let hasAnyBinding = updated.joysticks.contains { !$0.bindings.isEmpty }
        guard hasAnyBinding || updated.driveConfig?.enabled == true else {
            activity("Stopped \u{201C}\(updated.name)\u{201D}: it has no rows left")
            stop()
            // The store still marked it running; the menu bar clears that.
            NotificationCenter.default.post(name: Self.stoppedEmptyPresetNotification, object: updated.id)
            return
        }
        start(with: updated, isReload: true)
    }

    /// The parts of a preset the engine runs on, with the descriptive ones
    /// blanked, for telling a real edit from a rename.
    private static func runtimeShape(of preset: Preset) -> Preset {
        var p = preset
        p.name = ""
        p.tag = ""
        p.notes = ""
        p.filename = ""
        p.isActive = false
        p.createdAt = .distantPast
        p.modifiedAt = .distantPast
        p.sortOrder = nil
        p.groupID = nil
        p.activateHotKey = nil
        for g in p.joysticks.indices {
            p.joysticks[g].tag = ""
            // customName stays: it picks the controller the group reads
            // (effectiveSlot), so changing it is a real edit.
            p.joysticks[g].isExpanded = true
            for r in p.joysticks[g].bindings.indices {
                p.joysticks[g].bindings[r].note = nil
                p.joysticks[g].bindings[r].section = nil
            }
        }
        return p
    }

    init(controllerService: GameControllerService) {
        self.controllerService = controllerService
        installControllerDisconnectObserver()
        installSleepWakeObservers()
        presetSaveObserver = NotificationCenter.default.addObserver(
            forName: PresetStore.presetSavedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let preset = note.userInfo?["preset"] as? Preset else { return }
            MainActor.assumeIsolated { self?.activePresetWasEdited(preset) }
        }
    }

    /// Release every synthesized output when the machine sleeps, and refresh
    /// the controller set on wake. Without this, a key or mouse button held
    /// by a binding at the moment of sleep stayed logically down through the
    /// nap, and Bluetooth pads that dropped during sleep kept stale slots
    /// until the user opened the controller popover by hand.
    /// Why outputs are held back right now: the Mac asleep, the screen
    /// locked, or another user's session in front. (Not display sleep: a
    /// controller press has to reach the Mac to wake the display.) The
    /// poll loop keeps running (the emergency stop still works), but nothing
    /// is sent: a Return or Type Text row used to type into the login
    /// window's password field, and a latched Shift stayed held there.
    private var suspendReasons: Set<String> = []

    /// Outputs are held back while paused by the editor or suspended.
    private var outputsBlocked: Bool { outputsPaused || !suspendReasons.isEmpty || editorScanGate }

    // MARK: - Override in the editor

    /// Set by the host while the preset editor is open.
    var editorOpen = false {
        didSet { if !editorOpen { editorOverride = false; editorDraftHeld = false } }
    }

    /// Set by the editor while it holds an edit back from the running
    /// preset because running it would take away the way out of the editor
    /// (see `draftKeepsWayOut`); the banner then says it waits for Save.
    @Published var editorDraftHeld = false

    /// Whether the editor may run its unsaved draft on the running preset:
    /// the draft still has rows, and it keeps the pointer rows and the
    /// navigation-key rows (Escape, Return, Tab, arrows, Space) the saved
    /// preset has. Without them a controller-only user could no longer
    /// reach Undo, Cancel or Save, so such an edit waits for Save.
    static func draftKeepsWayOut(saved: Preset, draft: Preset) -> Bool {
        let hasRows = draft.joysticks.contains { !$0.bindings.isEmpty } || draft.driveConfig?.enabled == true
        guard hasRows else { return false }
        if hasPointerOutputs(saved) && !hasPointerOutputs(draft) { return false }
        if hasEditorSafeKeyRows(saved) && !hasEditorSafeKeyRows(draft) { return false }
        return true
    }

    /// Whether any row sends only keys the editor lets through.
    static func hasEditorSafeKeyRows(_ preset: Preset) -> Bool {
        preset.joysticks.contains { group in
            group.bindings.contains { row in
                let keys = row.outputs.filter { $0.type == .key }
                return !keys.isEmpty && keys.allSatisfy { editorSafeKeys.contains($0.keyCode ?? -1) }
            }
        }
    }

    /// Override, from the editor's paused banner: the running preset works
    /// fully while the editor is open, keys and MIDI included, for anyone
    /// who wants to try a change on the live preset or needs every output
    /// to get around. Off whenever the editor opens or closes.
    @Published var editorOverride = false {
        didSet {
            guard editorOverride != oldValue, editorOpen else { return }
            outputsPaused = !editorOverride
            if isRunning { log(editorOverride ? "Outputs on while editing (override)" : "Outputs paused while editing") }
        }
    }

    /// With the override on, a Scan (or a sheet waiting for a controller
    /// button) still holds every output back, so the press being scanned
    /// does not also fire its row.
    private var editorScanGate: Bool {
        editorOverride && editorOpen && (controllerService.isScanning || Self.editorListenerArmed)
    }
    private var lastEditorScanGate = false

    /// At the lock screen alone (not asleep, not another user's session),
    /// the pointer, clicks and scrolling still go through, so someone who
    /// uses the controller as their mouse is not stuck there: the login
    /// window's Accessibility Keyboard works by clicking. Keys and text
    /// stay blocked, so nothing can type into the password field by itself.
    /// Rows on a Mac modifier whose own modifier output was dropped; see
    /// selfModifierRows.
    private var selfModifierByRow: [UUID: Int] = [:]

    /// At the lock screen with the editor open, the pointer still works too,
    /// or a controller-only user who left the editor up was locked out.
    private var pointerOnlyAtLockScreen: Bool {
        suspendReasons == ["screen lock"] && (!outputsPaused || editorPassthroughApplies)
    }

    /// Set while the preset editor holds outputs back. The pointer, clicks
    /// and scrolling still go through, so someone who uses the controller
    /// as their mouse can reach Save and Cancel; keys, macros and MIDI stay
    /// paused. Off for a preset that moves the pointer from the touchpad,
    /// which would fling it while the touchpad is being set up, and while
    /// a Scan is listening, so the scanned press does not also click.
    var editorPointerPassthrough = false {
        didSet { if oldValue != editorPointerPassthrough, isRunning { installPollTimer() } }
    }
    /// Whether the running preset has pointer outputs at all, and none
    /// driven from the touchpad. Set at start, so a preset started while
    /// the editor is open is judged too, and a preset with no pointer rows
    /// keeps the editor's slow poll.
    private var presetSuitsEditorPassthrough = false
    var editorPassthroughApplies: Bool { editorPointerPassthrough && presetSuitsEditorPassthrough }
    private var pointerWhileEditing: Bool {
        outputsPaused && editorPassthroughApplies && suspendReasons.isEmpty
            && !controllerService.isScanning && !Self.editorListenerArmed
    }
    /// Set while a sheet over the editor waits for a controller button (the
    /// re-zero button in Motion Calibration), so that press does not also
    /// click wherever the pointer is.
    static var editorListenerArmed = false

    /// Whether any row of the preset sends a pointer output, leaving out
    /// touchpad rows when asked (they stay paused in the editor).
    static func hasPointerOutputs(_ preset: Preset, excludingTouchpad: Bool = false) -> Bool {
        preset.joysticks.contains { group in
            group.bindings.contains { row in
                if excludingTouchpad, row.input.type == .touchpad || row.input.type == .touchpadGesture { return false }
                let lists = [row.outputs] + [row.holdOutputs, row.doubleTapOutputs].compactMap { $0 }
                    + [row.macroSteps?.map(\.action) ?? []]
                return lists.contains { $0.contains { pointerOutputTypes.contains($0.type) } }
            }
        }
    }
    /// Only pointer outputs may go through right now.
    private var pointerOnly: Bool { pointerOnlyAtLockScreen || pointerWhileEditing }
    /// Row keys ("group:id") of touchpad rows, held back while editing.
    private var touchpadRowOwners: Set<String> = []
    /// Set while Touchpad Setup is open: touchpad pointer rows wait then,
    /// since a finger setting up zones would fling the pointer. Otherwise
    /// they pass in the editor, so a preset whose pointer is the touchpad
    /// can still reach Save and Cancel.
    static var touchpadSetupOpen = false

    private func touchpadHeldBack(owner: String) -> Bool {
        guard pointerWhileEditing, !pointerOnlyAtLockScreen, Self.touchpadSetupOpen,
              touchpadRowOwners.contains(where: { owner.hasPrefix($0) })
        else { return false }
        // A Steam Controller's trackpads are its pointer, and their rows
        // have no Touchpad Setup or zone drawing to protect: they pass, so
        // the controller can still reach Save and Cancel.
        let group = owner.split(separator: ":", maxSplits: 1).first.flatMap { Int($0) } ?? pollingJoystickIndex
        return !controllerService.isSteamSlot(slotForGroup[group] ?? group)
    }

    private static let pointerOutputTypes: Set<OutputType> = [.mouseButton, .mouseMotion, .mouseWheel, .mouseWheelStep]

    /// Keys that move around and answer the editor: Escape, Return, Tab,
    /// Space, the arrows, and Shift (for Shift Tab). They pass while the
    /// editor is open, so a preset that works the Mac by keyboard
    /// navigation does not shut its user in the sheet.
    private static let editorSafeKeys: Set<Int> = [41, 40, 43, 44, 79, 80, 81, 82, 225, 229]

    /// What still goes out while outputs are held back: pointer outputs,
    /// and in the editor a row whose keys are all safe keys (a row with
    /// Command Tab keeps none of its keys, rather than sending a bare Tab).
    private func passingOutputs(_ outputs: [OutputAction]) -> [OutputAction] {
        let keys = outputs.filter { $0.type == .key }
        let keysPass = pointerWhileEditing && !pointerOnlyAtLockScreen && !keys.isEmpty
            && keys.allSatisfy { Self.editorSafeKeys.contains($0.keyCode ?? -1) }
        return outputs.filter { Self.pointerOutputTypes.contains($0.type) || (keysPass && $0.type == .key) }
    }

    /// Whether a preset has rows the editor lets through: a pointer row,
    /// a touchpad pointer row, or a row of only safe keys.
    static func suitsEditorPassthrough(_ preset: Preset) -> Bool {
        hasPointerOutputs(preset) || hasEditorSafeKeyRows(preset)
    }

    private func suspend(_ reason: String) {
        let wasSuspended = !suspendReasons.isEmpty
        let wasPointerOnly = pointerOnlyAtLockScreen
        suspendReasons.insert(reason)
        suspendedSince[reason] = suspendedSince[reason] ?? Date()
        startReconcileTimer()
        // A second reason while the lock screen was letting the pointer
        // through (it locked, then slept): what the pointer rows hold goes.
        guard !wasSuspended || wasPointerOnly else { return }
        engineGeneration &+= 1   // in-flight macros, turbo and repeats stop
        driveProcessor.releaseAll()
        InputSimulator.shared.releaseAll()
        MIDIService.shared.releaseAllNotes()
        releaseHeldLights()
        MouseMotionPump.shared.setVelocity(x: 0, y: 0)
        MouseMotionPump.shared.setScrollVelocity(x: 0, y: 0)
        // Reset toggle latches and deferred tap/hold state so nothing
        // resolves against a press from before.
        clearLatches()
        CursorGuardService.shared.setSuspended(true)
        ExternalInputDeviceService.shared.setBlockingPaused(true)
        if isRunning { log("Outputs suspended: \(reason)") }
    }

    private func resume(_ reason: String) {
        suspendedSince[reason] = nil
        guard suspendReasons.remove(reason) != nil, suspendReasons.isEmpty else { return }
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        pitchAnchorReset = true
        // Presses at the lock screen still ran the latch logic (a toggle
        // turbo row came back as a running auto-clicker), so the latches
        // and anything started in that time are cleared again. activeStates
        // is kept: it holds what is pressed right now, so an input held
        // through the unlock does not fire until it is let go and pressed.
        // Clicks pressed at the lock screen (a drag-lock toggle, an
        // auto-click mid-pulse) are let go too, or the button stayed down
        // with its latch cleared.
        engineGeneration &+= 1
        InputSimulator.shared.releaseAll()
        MouseMotionPump.shared.setVelocity(x: 0, y: 0)
        MouseMotionPump.shared.setScrollVelocity(x: 0, y: 0)
        clearLatches()
        CursorGuardService.shared.setSuspended(outputsBlocked)
        ExternalInputDeviceService.shared.setBlockingPaused(outputsBlocked)
        if isRunning { log("Outputs resumed") }
    }

    /// Clears every press latch: toggles, turbo, tap and hold decisions,
    /// chords, repeats and macro bookkeeping. Called when outputs are
    /// paused or resumed and when the Mac sleeps, locks or wakes.
    private func clearLatches() {
        toggleStates.removeAll()
        turboPulseDown.removeAll()
        turboTimestamps.removeAll()
        turboCounts.removeAll()
        deferredPressStart.removeAll()
        modifierKeyDownMark.removeAll()
        holdFired.removeAll()
        lastTapTime.removeAll()
        pendingSingleTapToken.removeAll()
        secondTapPressed.removeAll()
        repeatsInFlight.removeAll()
        macrosInFlight.removeAll()
        macroCancelRequests.removeAll()
    }

    /// When each reason began, so a missed ending can be noticed.
    private var suspendedSince: [String: Date] = [:]
    private var reconcileTimer: Timer?

    private func startReconcileTimer() {
        guard reconcileTimer == nil else { return }
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileSuspendReasons() }
        }
        reconcileTimer?.tolerance = 0.5
    }

    /// The pairs of notifications are trusted, but not only: one missed
    /// unlock, wake or session return held every key back until relaunch.
    /// The real session state drops a reason that no longer holds. A reason
    /// is a few seconds old first, so a lock is not undone before the
    /// session itself says locked. Sleep has no state to read; a timer that
    /// still runs a minute after the Mac went to sleep means it is awake.
    func reconcileSuspendReasons() {
        guard !suspendReasons.isEmpty else {
            reconcileTimer?.invalidate(); reconcileTimer = nil
            return
        }
        let now = Date()
        func old(_ reason: String, _ seconds: TimeInterval) -> Bool {
            suspendedSince[reason].map { now.timeIntervalSince($0) > seconds } ?? true
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let onConsole = session?[kCGSessionOnConsoleKey as String] as? Bool ?? true
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if suspendReasons.contains("screen lock"), !locked, onConsole, old("screen lock", 3) {
            log("Outputs: the screen is unlocked, though no unlock notice arrived")
            resume("screen lock")
        }
        if suspendReasons.contains("user switch"), onConsole, old("user switch", 3) {
            log("Outputs: this session is back, though no notice arrived")
            resume("user switch")
        }
        if suspendReasons.contains("sleep"), old("sleep", 60) {
            log("Outputs: the Mac is awake, though no wake notice arrived")
            resume("sleep")
        }
    }

    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "user switch"),
        ]
        for (off, on, reason) in pairs {
            center.addObserver(forName: off, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend(reason) }
            }
            center.addObserver(forName: on, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.resume(reason)
                    if reason == "sleep" { self?.controllerService.refreshControllers() }
                }
            }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend("screen lock") }
        }
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume("screen lock") }
        }
    }

    /// Drop cached active-input / toggle / turbo / macro state for any
    /// controller slot that has gone out of range whenever the controller set
    /// changes. Without this, a controller that disconnects mid-press leaves
    /// orphaned bindKeys in toggleStates + turboTimestamps + macrosInFlight;
    /// when the user reconnects to a different slot the same UUID is now under a
    /// fresh bindKey, but the OLD bindKey is still flagged "toggled on", which
    /// shows the binding as latched with no way to turn it off.
    ///
    /// This subscribes to GameControllerService.$connectedControllers rather
    /// than the raw GCControllerDidDisconnect notification. The notification
    /// fired concurrently with GameControllerService's own observer (which
    /// rebuilds connectedControllers and the virtual slots), so reading the slot
    /// count in the handler raced and could see a stale value. Delivered on the
    /// main runloop, the publisher fires AFTER the rebuild, so cleanup always
    /// sees the authoritative slot count. On a connect, only a group whose
    /// slot now holds a different controller is reset, and only its own
    /// outputs are let go. Storing the cancellable also fixes the previous fire-and-forget
    /// NotificationCenter observer, which was never removed.
    private func installControllerDisconnectObserver() {
        controllerListSubscription = controllerService.$connectedControllers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cleanupAfterControllerDisconnect()
            }
        // Raw HID pads come and go without touching connectedControllers
        // (a GameCube adapter port, a pad swapped on the same USB port).
        rawSlotSubscription = controllerService.$rawHIDGamepadSlots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cleanupAfterControllerDisconnect()
            }
        // The Steam Controller's slot too: its disconnect touched neither
        // list, so a toggled key or auto-click on it kept going.
        steamSlotSubscription = controllerService.$steamControllerSlot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cleanupAfterControllerDisconnect()
            }
        // A re-zero (Quick Zero, the re-zero button, Motion Calibration)
        // restarts the tilt estimate, so the pointer's neutral moves with
        // it; keeping the old anchor made the pointer leap.
        rezeroObserver = NotificationCenter.default.addObserver(
            forName: GameControllerService.motionRezeroedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchorMotion() }
        }
    }
    private var rezeroObserver: NSObjectProtocol?

    /// Wipe per-bindKey state for any controller slot whose index is
    /// now out of range. Re-runs after refreshControllers() so the
    /// connected-controllers count is up to date. Belt-and-suspenders:
    /// also release any keys / mouse buttons currently held - if the
    /// disconnect happened while a binding was firing a continuous
    /// output (mouse motion, scroll), the poll loop's next tick won't
    /// see the input as active and the release path normally clears
    /// it, but a stuck simulated key on disconnect is the kind of
    /// stuck-output bug that's hard to undo without a relaunch.
    private func cleanupAfterControllerDisconnect() {
        // A pad that came back is a new controller with a fresh tilt
        // estimate; the old anchor would make the pointer leap.
        pitchAnchorReset = true
        // Which controller holds each slot now. A slot whose controller left,
        // or was replaced by another, invalidates the state of every group
        // that reads it. Groups are compared by the slot they actually read,
        // not by their position: comparing a two-group preset's keyboard or
        // MIDI group against the controller count treated it as stale on
        // every refresh and released everything each time.
        var occupants: [Int: String] = [:]
        for slot in 0..<32 {
            if let token = controllerService.occupantToken(forSlot: slot) { occupants[slot] = token }
        }
        let changedSlots = Set(slotOccupants.compactMap { slot, old in occupants[slot] != old ? slot : nil })
        slotOccupants = occupants
        guard !changedSlots.isEmpty, let preset = activePreset else { return }

        let controllerTypes: Set<InputType> = [.button, .axis, .hat, .touchpad, .touchpadRegion,
                                               .touchpadGesture, .motion, .stickRegion]
        let affected = preset.joysticks.indices.filter { g in
            let readsController = preset.joysticks[g].bindings.contains { controllerTypes.contains($0.input.type) }
            return readsController && changedSlots.contains(slotForGroup[g] ?? g)
        }
        guard !affected.isEmpty else { return }
        for g in affected {
            activeStates[g] = nil
            rowActiveStates[g] = nil
            let prefix = "\(g):"
            toggleStates = toggleStates.filter { !$0.key.hasPrefix(prefix) }
            turboTimestamps = turboTimestamps.filter { !$0.key.hasPrefix(prefix) }
            turboCounts = turboCounts.filter { !$0.key.hasPrefix(prefix) }
            macrosInFlight = macrosInFlight.filter { !$0.hasPrefix(prefix) }
            secondTapPressed = secondTapPressed.filter { !$0.hasPrefix(prefix) }
            lastTapTime = lastTapTime.filter { !$0.key.hasPrefix(prefix) }
            // Running chains on these rows stop pressing (their press hop
            // checks the token), so a new press does not run a second chain.
            macroChainToken = macroChainToken.filter { !$0.key.hasPrefix(prefix) }
            // And repeat runs (repeatStep checks its entry before each press).
            repeatsInFlight = repeatsInFlight.filter { !$0.key.hasPrefix(prefix) }
        }
        // Let go of what the affected groups hold, and only that. Releasing
        // everything turned off every toggle and let go of keys and MIDI
        // notes on the other controllers too, whenever a pad connected and
        // shifted a slot.
        for g in affected {
            let prefix = "\(g):"
            InputSimulator.shared.releaseOwners(withPrefix: prefix)
            releaseHeldLights(withPrefix: prefix)
            for row in preset.joysticks[g].bindings {
                for output in row.outputs + (row.holdOutputs ?? []) {
                    let ch = output.midiChannel ?? 1
                    switch output.type {
                    case .midiNote:
                        MIDIService.shared.sendNoteOff(note: output.midiNote ?? 60, channel: ch)
                    // A bend or a held CC (sustain) goes back to rest too:
                    // its release edge can no longer come once the row's
                    // state is wiped, and the synth stayed detuned or held.
                    case .midiCC:
                        let rest = row.input.type == .axis && row.input.axisDirection == nil ? 64 : 0
                        MIDIService.shared.sendCC(controller: output.midiCCNumber ?? 1, value: rest, channel: ch)
                    case .midiPitchBend:
                        MIDIService.shared.sendPitchBend(value: 8192, channel: ch)
                    default:
                        break
                    }
                }
            }
            deferredPressStart = deferredPressStart.filter { !$0.key.hasPrefix(prefix) }
            modifierKeyDownMark = modifierKeyDownMark.filter { !$0.key.hasPrefix(prefix) }
            holdFired = holdFired.filter { !$0.hasPrefix(prefix) }
            lastTapTime = lastTapTime.filter { !$0.key.hasPrefix(prefix) }
        }
        if let drive = preset.driveConfig, drive.enabled, changedSlots.contains(drive.slot) {
            driveProcessor.releaseAll()
        }
    }

    // MARK: - Start / Stop

    /// Mouse buttons a preset asks to block: middle and side button rows
    /// with "Block the button's own action" on.
    static func blockedMouseButtons(in preset: Preset) -> Set<Int> {
        var out = Set<Int>()
        for group in preset.joysticks {
            // Mouse buttons arrive through one event tap that cannot tell
            // mice apart, so only a row for any mouse (or that tap's own
            // mouse) blocks; a row bound to one particular device never
            // fires from the tap and must not silence every mouse.
            for row in group.bindings where row.blockOriginal == true
                && row.input.type == .extMouse && (row.input.extMouseKind ?? .button) == .button
                && row.input.index >= 2
                && [nil, "any", ExternalInputDeviceService.builtInMouseID].contains(row.input.extDeviceID) {
                out.insert(row.input.index)
            }
        }
        return out
    }

    /// True when a blocking row for this mouse button sends a click,
    /// pointer move or scroll, which passes while outputs are paused.
    private static func mouseButtonRowSendsPointer(_ button: Int, in preset: Preset) -> Bool {
        preset.joysticks.contains { group in
            group.bindings.contains { row in
                row.blockOriginal == true && row.input.type == .extMouse
                    && (row.input.extMouseKind ?? .button) == .button && row.input.index == button
                    && (row.outputs + (row.holdOutputs ?? []) + (row.doubleTapOutputs ?? []))
                        .contains { pointerOutputTypes.contains($0.type) }
            }
        }
    }

    /// Posted on the main thread when a preset starts or stops running.
    static let didStartNotification = Notification.Name("InputConfig.engine.didStart")
    static let didStopNotification = Notification.Name("InputConfig.engine.didStop")
    /// Posted when the running preset was saved with no rows left and
    /// stopped; the object is its id.
    static let stoppedEmptyPresetNotification = Notification.Name("InputConfig.engine.stoppedEmptyPreset")

    /// Settings' Speed times the preset's own multiplier, refreshed once
    /// per second rather than read through two published properties on
    /// every poll frame.
    private var pointerGain: Float {
        let now = CACurrentMediaTime()
        if now - pointerGainCheckedAt > 1 {
            pointerGainCheckedAt = now
            let global = Float(CursorGuardService.shared.sensitivityMultiplier)
            let preset = Float(activePreset?.automation.sensitivityMultiplier ?? 1)
            let g = global * preset
            pointerGainCache = (g.isFinite && g > 0) ? g : 1
            let s = Float(activePreset?.automation.scrollMultiplier ?? 1)
            scrollGainCache = (s.isFinite && s > 0) ? s : 1
        }
        return pointerGainCache
    }
    private var pointerGainCache: Float = 1
    /// The preset's Scroll speed, refreshed with pointerGain; read it after.
    private var scrollGainCache: Float = 1
    private var pointerGainCheckedAt: CFTimeInterval = 0

    /// Every input type the preset reads: each row's own input plus the
    /// controls it holds as a chord.
    private static func inputTypesUsed(by preset: Preset) -> Set<InputType> {
        var types = Set<InputType>()
        for group in preset.joysticks {
            for b in group.bindings {
                types.insert(b.input.type)
                for m in b.modifiers { types.insert(m.type) }
            }
        }
        return types
    }

    func start(with preset: Preset) {
        start(with: preset, isReload: false)
    }

    private func start(with preset: Preset, isReload: Bool) {
        // Decide first whether this preset can run at all. Everything below
        // touches live state (the region working sets, the chassis sensor,
        // the slot map), and doing that before this check meant activating
        // an empty preset while another was running replaced the running
        // preset's zones with nothing and left it dead.
        guard preset.isRunnable else { return }
        // A stale sleep, lock or user-switch reason is dropped here too:
        // starting a preset again is what a user tries first.
        reconcileSuspendReasons()
        CursorGuardService.shared.setSuspended(outputsBlocked)
        // Share, Create and Capture are taken from macOS only when a row
        // uses them (see GameControllerService.buttonsInUse).
        // The emergency-stop hold's buttons must arrive too, but macOS can
        // keep its own action on them (see emergencyButtons).
        let emergency = EmergencyStopService.shared
        controllerService.buttonsInUse = Set(preset.joysticks.flatMap(\.bindings)
            .flatMap { [$0.input] + $0.modifiers }.filter { $0.type == .button }.map(\.index))
        controllerService.emergencyButtons = !emergency.controllerHoldEnabled ? []
            : emergency.holdNeedsStart ? [emergency.controllerButton, EmergencyStopService.startButton]
            : [emergency.controllerButton]
        restartWatch?.invalidate()
        restartWatch = nil
        if !isReload { MIDIInputService.shared.clearMomentaryHits() }
        if !isReload {
            // Rating ask: counts real use, so the card only appears for
            // someone who has been running presets for a while.
            ReviewPromptService.shared.recordActivation()
            lastActivityAt = [:]
            activity("Started \u{201C}\(preset.name)\u{201D}")
        }
        // Make start() idempotent. The "edit the currently-active preset"
        // path re-enters start() with no intervening stop(); without this,
        // reference-counted services (touchpad helper, cursor-region timer,
        // system-stats timer, external-input monitors) get retained again
        // and never balanced, leaking a live subprocess and timers, and
        // stale deferred-tap/toggle state carries into the reloaded preset.
        // It runs before any service is retained below: stop() releases
        // them, and a retain placed ahead of it was being released a few
        // lines later, which switched the chassis sensor off on every
        // re-activation.
        if isRunning { stop(isReload: isReload) }

        // This preset's touchpad, screen, and stick regions are the ones
        // the engine tests against from now on.
        preset.applyRegionsToServices()
        slotForGroup = [:]
        pitchAnchorReset = true
        loggedSlotRedirect = [:]
        // Every input a row listens to, including the controls it holds as
        // a chord. A row whose modifier is a MIDI note or a screen region
        // needs that service running as much as a row whose input is.
        let inputTypes = Self.inputTypesUsed(by: preset)
        // The Mac's own accelerometer streams at ~800 Hz, so only wake it when
        // this preset actually binds a chassis tap.
        if inputTypes.contains(.chassisTap) {
            ChassisTapService.shared.retain("engine")
        } else {
            ChassisTapService.shared.release("engine")
        }

        debugEnabled = UserDefaults.standard.bool(forKey: Self.debugLogDefaultsKey)
        if debugSettingObserver == nil {
            debugSettingObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.debugEnabled = UserDefaults.standard.bool(forKey: Self.debugLogDefaultsKey)
                }
            }
        }

        activePreset = preset
        ExternalInputDeviceService.shared.setBlockingPaused(outputsBlocked)
        ExternalInputDeviceService.shared.pointerOutputsPassing = { [weak self] in
            MainActor.assumeIsolated { self?.pointerOnly ?? false }
        }
        let blocked = Self.blockedMouseButtons(in: preset)
        ExternalInputDeviceService.shared.setBlockedMouseButtons(
            blocked, pointerRows: blocked.filter { Self.mouseButtonRowSendsPointer($0, in: preset) })
        // The 30 Hz snapshot loop feeds the touchpad of pads macOS gives no
        // typed Sony class; the engine reads everything else itself. Kept
        // off otherwise, so a running preset does not wake the app 30 more
        // times a second for nothing.
        // Motion presets keep it too: the controller re-zero button chosen
        // in Motion Calibration is handled in the same loop.
        if inputTypes.contains(.touchpad) || inputTypes.contains(.touchpadRegion)
            || inputTypes.contains(.touchpadGesture) || inputTypes.contains(.motion) {
            controllerService.retainLiveInput("engine")
        } else {
            controllerService.releaseLiveInput("engine")
        }
        NotificationCenter.default.post(name: Self.didStartNotification, object: nil)
        pointerGainCheckedAt = 0   // pick up this preset's Speed at once
        let selfMods = Self.selfModifierRows(preset.joysticks)
        pollJoysticks = selfMods.groups
        // Touchpad rows stay paused in the editor, but the preset's other
        // pointer rows pass: Touchpad Mouse's Cross and Circle clicks were
        // paused too, and a controller-only user could not reach Save.
        presetSuitsEditorPassthrough = Self.suitsEditorPassthrough(preset)
        touchpadRowOwners = Set(preset.joysticks.enumerated().flatMap { j, group in
            group.bindings.filter { $0.input.type == .touchpad || $0.input.type == .touchpadGesture }
                .map { "\(j):\($0.id.uuidString)" }
        })
        // The Steam Controller's own mouse and keys go off while a preset
        // runs and sends something, as Help says. Set on every start, reloads
        // included, by the same rule as pausing: a preset switch or an edit
        // while paused turned them off with nothing sent in their place.
        SteamControllerService.shared.setLizardModeOff(!outputsPaused || editorPassthroughApplies)
        selfModifierByRow = selfMods.dropped
        pollDriveConfig = preset.driveConfig
        isRunning = true
        engineGeneration &+= 1
        activeStates.removeAll()
        rowActiveStates.removeAll()
        armedAppActionRows.removeAll()
        holdBackHeldRows()
        appActionRowCache.removeAll()
        activeInputs.removeAll()
        toggleStates.removeAll()
        turboTimestamps.removeAll()
        turboPulseDown.removeAll()
        turboCounts.removeAll()
        macrosInFlight.removeAll()
        // Per-session state that used to survive start() and stop(). A
        // holdFired entry left over from the previous run swallowed the next
        // tap and sent a phantom key-up; a stale chordKeyCache entry kept
        // edge-detecting an edited chord under its old key forever.
        deferredPressStart.removeAll()
        modifierKeyDownMark.removeAll()
        holdFired.removeAll()
        lastTapTime.removeAll()
        secondTapPressed.removeAll()
        pendingSingleTapToken.removeAll()
        chordKeyCache.removeAll()
        chordLatched.removeAll()
        repeatsInFlight.removeAll()
        macroCancelRequests.removeAll()
        lastSlotState.removeAll()
        serializedKeyCache.removeAll()
        bindKeyCache.removeAll()
        debugLog.removeAll()
        pendingLog.removeAll()
        debugLineCount = 0

        for i in preset.joysticks.indices {
            activeStates[i] = Set<String>()
        }

        // Pre-build the serialized-input-event cache for every binding
        // so the hot poll loop's `cachedKey(for:)` always hits the
        // cache. Without this, the first ~N polls each pay the
        // serialization cost (string interpolation + Codable
        // resolution) on a freshly-active preset. Building it once
        // here is O(N) on a quiet thread.
        for joystick in preset.joysticks {
            for binding in joystick.bindings {
                if serializedKeyCache[binding.id] == nil {
                    serializedKeyCache[binding.id] = binding.input.serialized
                }
            }
        }

        if !isReload { StatsService.shared.engineStarted(presetName: preset.name) }
        log("Engine started with preset: \(preset.name)")
        log("Joysticks: \(preset.joysticks.count), Total bindings: \(preset.joysticks.flatMap(\.bindings).count)")
        log("Connected controllers: \(controllerService.connectedControllers.count)")

        // Hold the touchpad only when the preset uses touchpad inputs, so its
        // touch state is reset when the preset stops.
        let usesTouchpad = inputTypes.contains(.touchpad) || inputTypes.contains(.touchpadRegion)
            || inputTypes.contains(.touchpadGesture)
        if usesTouchpad {
            TouchpadService.shared.retain()
            TouchpadService.second.retain()
            TouchpadService.steamRight.retain()
            usesTouchpadInput = true
            log("Touchpad input enabled")
        } else {
            usesTouchpadInput = false
        }

        // Cursor-region bindings read the live cursor position. That used
        // to arrive via the system event tap; it now comes from a
        // permission-free NSEvent.mouseLocation poll owned by
        // CursorRegionService. Only start it when the preset actually
        // uses a cursor region, and balance it in stop().
        let usesCursorRegion = inputTypes.contains(.cursorRegion)
        if usesCursorRegion {
            CursorRegionService.shared.beginTracking()
            usesCursorRegionInput = true
            log("Cursor region tracking enabled")
        } else {
            usesCursorRegionInput = false
        }

        for (i, ctrl) in controllerService.connectedControllers.enumerated() {
            log("  Controller \(i): \(ctrl.vendorName ?? "Unknown"), hasExtendedGamepad: \(ctrl.extendedGamepad != nil)")
        }

        // Open the MIDI input port when this preset binds anything to a
        // MIDI message, so a keyboard / pad controller is live the moment
        // the preset activates. Cheap to leave open, but there is no
        // reason to hold a CoreMIDI client for presets that never use it.
        let usesMIDIInput = inputTypes.contains(.midi)
        if usesMIDIInput {
            // The client is opened at launch for the whole session (the
            // device list and the visualizer's MIDI view read it too), so
            // this only reconnects sources; nothing to close on stop.
            MIDIInputService.shared.start()
            log("MIDI input opened for this preset")
        }

        // Fader (absolute volume) engagement resets on every activation:
        // the volume must never jump to wherever a knob happens to be
        // sitting. Each fader binding re-arms below by observing its
        // control's resting position and engaging only once the user
        // actually moves it.
        faderBaseline.removeAll()
        faderEngaged.removeAll()

        // Push the preset's light-bar override (if any) so every
        // light-capable controller flashes the preset's color while it's
        // active. We apply temporarily - the slot's stored default color is
        // untouched, so revert in stop() simply re-asserts it.
        #if DEBUG
        controllerService.debugTempLightLog.append(
            "start override=\(preset.lightBarColor.map { "(\($0.r),\($0.g),\($0.b))" } ?? "nil") "
            + "slots=\(Array(controllerService.controllerDetails.keys).sorted()) "
            + "hasLight=\(controllerService.controllerDetails.mapValues { $0.hasLight })")
        #endif
        if preset.lightBarRainbow == true {
            // The preset's rainbow, at its own speed, until stop() reverts it.
            let bri: UInt8? = preset.lightBarBrightness.map { UInt8(max(0, min(2, $0))) }
            controllerService.applyPresetRainbow(speed: preset.lightBarRainbowSpeed ?? 1, brightness: bri)
            log("Applied preset light-bar rainbow")
        } else if let override = preset.lightBarColor {
            // Handed over as the standing override rather than written once:
            // a controller that connects later, or reconnects, then lands on
            // the preset's color instead of the slot default.
            let bri: UInt8? = preset.lightBarBrightness.map { UInt8(max(0, min(2, $0))) }
            controllerService.applyPresetLight(
                red: override.floatR, green: override.floatG,
                blue: override.floatB, brightness: bri)
            log("Applied preset light-bar override (\(override.r),\(override.g),\(override.b))")
        }

        // Polling rate is configurable from Settings → General → Polling Rate.
        // Default 120 Hz balances latency vs. UI cost; 240 doubles latency
        // headroom but cascades twice as many @Published mirror writes, so
        // the editor sheet can hitch. 60 cuts CPU in half but feels laggy
        // for fast-twitch inputs. Stored in UserDefaults so it persists.
        dpadOneWay = preset.automation.dpadOneDirection == true
        dpadHeldAxis.removeAll()
        // MIDI too: its input wakes the poll the moment a message arrives.
        let controllerOnly: Set<InputType> = [.button, .axis, .hat, .midi]
        idleEligible = inputTypes.isSubset(of: controllerOnly) && preset.driveConfig?.enabled != true
        idlePolling = false
        lastInputChangeAt = CACurrentMediaTime()
        controllerService.onInputActivity = idleEligible ? { [weak self] in self?.noteInputActivity() } : nil
        MIDIInputService.shared.setActivityHandler(idleEligible && inputTypes.contains(.midi)
            ? { [weak self] in MainActor.assumeIsolated { self?.noteInputActivity() } } : nil)
        // Retained before the poll timer's rate is chosen, so the power
        // source is already known: the first preset of a session ran at
        // the AC rate on battery until the next plug or unplug.
        if !holdsSystemStats {
            SystemStatsService.shared.retain()
            holdsSystemStats = true
        }
        installPollTimer()
        // The pump is a 125 Hz strict timer; it only runs for a preset that
        // can move the pointer or scroll. Every other service here is gated
        // on use, and this one was the exception: four keyboard bindings
        // paid for 125 wakeups a second they never used.
        let movesPointer = preset.joysticks.contains { group in
            group.bindings.contains { row in
                (row.outputs + (row.holdOutputs ?? []) + (row.doubleTapOutputs ?? [])).contains {
                    $0.type == .mouseMotion || $0.type == .mouseWheel || $0.type == .mouseWheelStep
                }
            }
        } || preset.driveConfig?.enabled == true
        if movesPointer { MouseMotionPump.shared.start() }

        // Per-preset automation: apply CursorGuard overrides + auto-
        // launch any app the preset names. Applied BEFORE the cursor-
        // guard engine flag flips so the new settings are already in
        // place when the service activates.
        CursorGuardService.shared.applyPresetOverride(preset.automation)
        if !isReload { applyPresetAutoLaunch(preset.automation) }

        // Let the cursor-guard service know the engine is up so it can
        // hide the system cursor / start its recenter loop if the user
        // enabled those toggles.
        CursorGuardService.shared.engineDidChangeState(running: true)

        // Watch power-source transitions so applyPollRate() runs
        // exactly once per plug / unplug when the user has enabled
        // "Auto-switch on power source" in Settings. Retain the
        // SystemStatsService poll timer for the duration so the
        // source field is actually being updated.
        lastSeenPowerSource = SystemStatsService.shared.power.source
        powerSourceSubscription = SystemStatsService.shared.$power
            .map(\.source)
            .removeDuplicates()
            .sink { [weak self] newSource in
                guard let self = self else { return }
                let auto = UserDefaults.standard
                    .bool(forKey: "InputConfig.autoPollHzByPower")
                guard auto, newSource != self.lastSeenPowerSource else { return }
                self.lastSeenPowerSource = newSource
                self.applyPollRate()
            }

        // Subscribe to external keyboard / mouse events for the lifetime of
        // this preset. Both paths ride only on the approved Accessibility
        // permission (mouse via a listen-only CGEventTap, keyboard via NSEvent
        // monitors); neither uses Input Monitoring. Our own posted output
        // events carry an own-event marker, so they are filtered out and
        // cannot loop back in as input.
        let usesExtMouse = inputTypes.contains(.extMouse)
        let usesExtKey = inputTypes.contains(.extKey)
        if usesExtMouse || usesExtKey {
            externalEventSubscription = ExternalInputDeviceService.shared.events
                .receive(on: DispatchQueue.main)
                .sink { [weak self] event in
                    self?.ingestExternalEvent(event)
                }
            // Hold only what the preset actually needs; the visualizer and
            // the editor's Scan hold their own, so stopping the engine
            // never pulls a monitor out from under them.
            let readsMovement = preset.joysticks.contains { $0.bindings.contains {
                $0.input.type == .extMouse && [.moveX, .moveY].contains($0.input.extMouseKind ?? .button)
            } }
            ExternalInputDeviceService.shared.retain("engine", mouse: usesExtMouse, keyboard: usesExtKey,
                                                     movement: readsMovement)
            if usesExtMouse { log("External mouse input enabled") }
            if usesExtKey { log("External keyboard input enabled") }
        }

        // Flush log entries to the @Published array at 5 Hz so observers
        // of mappingEngine do not re-render on every input event.
        logFlushTimer?.invalidate()
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushPendingLog()
            }
        }
        RunLoop.main.add(logFlushTimer!, forMode: .common)
    }

    /// (Re-)installs the controller poll timer using the current
    /// `InputConfig.pollHz` UserDefaults value. Called from start()
    /// during initial install and from `applyPollRate()` when the user
    /// changes the rate in Settings while the engine is already
    /// running. Clamped to [30, 240] to keep CPU sane.
    func installPollTimer() {
        pollTimer?.invalidate()
        let fullHz = resolveEffectivePollHz()
        // Idle polling is not shown as the engine's rate: it is the same
        // setting, only resting until the controller is touched.
        let pollHz = idlePolling ? min(Self.idlePollHz, fullHz) : fullHz
        let pollInterval: TimeInterval = 1.0 / Double(pollHz)
        MouseMotionPump.shared.setPollInterval(pollInterval)
        currentPollHz = fullHz
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // Fires on RunLoop.main (main thread = main actor). Run inline
            // rather than spawning a Task per tick (an allocation + actor hop
            // up to 240x/second) for identical behavior.
            MainActor.assumeIsolated {
                self?.pollControllers()
            }
        }
        pollTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Reads UserDefaults and decides what rate the engine should
    /// actually run at right now. When auto-switching is off, returns
    /// the saved `pollHz`. When on, returns the battery rate if the
    /// Mac is currently on battery (per SystemStatsService.power.source),
    /// else the AC rate. Clamped to [30, 240].
    /// Poll rate while an editor sheet has outputs paused. Nothing can fire
    /// at all in that state, so 120 Hz is pure waste: it was the single
    /// biggest main-thread cost measured while scrolling the binding editor.
    /// Not zero, because the controller's emergency-stop hold is checked in
    /// the same loop and has to stay responsive; a 2-second hold is still
    /// sampled 30 times at this rate.
    private static let pausedPollHz = 15

    private func resolveEffectivePollHz() -> Int {
        outputsPaused && !editorPassthroughApplies ? Self.pausedPollHz : Self.configuredPollHz()
    }

    /// The rate the settings ask for right now, the one place it is worked
    /// out: Settings shows this, and the engine runs at it. The AC rate
    /// falls back to the single `pollHz` when it was never set.
    static func configuredPollHz() -> Int {
        let defaults = UserDefaults.standard
        let autoSwitch = defaults.bool(forKey: "InputConfig.autoPollHzByPower")
        let fallback = defaults.object(forKey: "InputConfig.pollHz") as? Int ?? 120
        let rate: Int
        if autoSwitch {
            let acRate = defaults.object(forKey: "InputConfig.pollHzOnAC") as? Int ?? fallback
            let battRate = defaults.object(forKey: "InputConfig.pollHzOnBattery") as? Int ?? 60
            let source = (SystemStatsService.shared.power.source ?? "").lowercased()
            rate = source.contains("battery") ? battRate : acRate
        } else {
            rate = fallback
        }
        return max(30, min(240, rate))
    }

    /// Re-read the poll-rate setting from UserDefaults and rebuild the
    /// timer in place. Safe to call from a SwiftUI `.onChange` while
    /// the engine is running - the only externally visible effect is a
    /// brief one-tick gap while the old timer is torn down and the new
    /// one starts.
    func applyPollRate() {
        guard isRunning else {
            // Engine isn't running - just bump the cached rate so the
            // settings UI's "current rate" label updates immediately.
            currentPollHz = Self.configuredPollHz()
            return
        }
        let oldHz = currentPollHz
        installPollTimer()
        log("Poll rate live-updated: \(oldHz) Hz → \(currentPollHz) Hz")
    }

    /// Open the application the preset names, if any. Accepts a posix
    /// path ("/Applications/Steam.app") or a bundle identifier
    /// ("com.valvesoftware.steam"). Empty string = no-op. Optionally
    /// follows the path with `NSWorkspace.open(url:)` on a non-empty
    /// launchURL so a preset can deep-link to a specific game via a
    /// steam:// or itch:// scheme.
    private func applyPresetAutoLaunch(_ automation: PresetAutomation) {
        let trimmedApp = automation.launchAppPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedApp.isEmpty {
            let ws = NSWorkspace.shared
            if trimmedApp.hasPrefix("/") {
                let url = URL(fileURLWithPath: trimmedApp)
                ws.openApplication(at: url,
                                   configuration: NSWorkspace.OpenConfiguration(),
                                   completionHandler: nil)
            } else if let url = ws.urlForApplication(withBundleIdentifier: trimmedApp) {
                ws.openApplication(at: url,
                                   configuration: NSWorkspace.OpenConfiguration(),
                                   completionHandler: nil)
            } else {
                log("Preset auto-launch: couldn't resolve \(trimmedApp)")
            }
        }
        let trimmedURL = automation.launchURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty, let url = URL(string: trimmedURL) {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        stop(isReload: false)
    }

    private func stop(isReload: Bool) {
        if !isReload, isRunning, let name = activePreset?.name { activity("Stopped \u{201C}\(name)\u{201D}") }
        idlePolling = false
        idleEligible = false
        if !isReload { controllerService.buttonsInUse = []; controllerService.emergencyButtons = [] }
        controllerService.onInputActivity = nil
        MIDIInputService.shared.setActivityHandler(nil)
        controllerService.touchpadSourceSlot = nil
        controllerService.touchpadSecondSourceSlot = nil
        controllerService.touchpadSteamSourceSlot = nil
        secondTouchGroups = nil
        steamTouchGroups = nil
        motionRecenter = nil
        MouseMotionPump.shared.stop()
        smoothedAxes.removeAll()
        smoothedAt.removeAll()
        rampStart.removeAll()
        lastFrameTime = 0
        ChassisTapService.shared.release("engine")
        if !isReload { StatsService.shared.engineStopped() }
        engineGeneration &+= 1   // poison any in-flight macro/turbo blocks
        pollTimer?.invalidate()
        pollTimer = nil
        logFlushTimer?.invalidate()
        logFlushTimer = nil
        isRunning = false
        // Clear deferred state so a future start() with a different
        // preset doesn't see stale toggle / turbo / cache entries.
        toggleStates.removeAll()
        turboTimestamps.removeAll()
        turboPulseDown.removeAll()
        turboCounts.removeAll()
        macrosInFlight.removeAll()
        // Per-session state that used to survive start() and stop(). A
        // holdFired entry left over from the previous run swallowed the next
        // tap and sent a phantom key-up; a stale chordKeyCache entry kept
        // edge-detecting an edited chord under its old key forever.
        deferredPressStart.removeAll()
        modifierKeyDownMark.removeAll()
        holdFired.removeAll()
        lastTapTime.removeAll()
        secondTapPressed.removeAll()
        pendingSingleTapToken.removeAll()
        chordKeyCache.removeAll()
        chordLatched.removeAll()
        repeatsInFlight.removeAll()
        macroCancelRequests.removeAll()
        lastSlotState.removeAll()
        serializedKeyCache.removeAll()
        bindKeyCache.removeAll()
        externalEventSubscription?.cancel()
        externalEventSubscription = nil
        // Blocking ends before the monitor is let go, so a blocked button
        // still held keeps its tap until its release (which is swallowed).
        ExternalInputDeviceService.shared.setBlockedMouseButtons([])
        ExternalInputDeviceService.shared.release("engine")
        externalDoubleClickUntil.removeAll()
        externalScrollGestureActive.removeAll()
        externalKeysDown.removeAll()
        externalMouseButtonsDown.removeAll()
        externalMouseDX.removeAll()
        externalMouseDY.removeAll()
        externalScrollDX.removeAll()
        externalScrollDY.removeAll()
        driveProcessor.releaseAll()
        InputSimulator.shared.releaseAll()
        MIDIService.shared.releaseAllNotes()
        controllerService.releaseLiveInput("engine")
        // Not on a reload, which starts again at once: each edit of the
        // running preset turned the Steam Controller's own mouse on and off
        // and stopped and restarted the pad polls.
        if !isReload { NotificationCenter.default.post(name: Self.didStopNotification, object: nil) }
        if usesTouchpadInput {
            TouchpadService.shared.release()
            TouchpadService.second.release()
            TouchpadService.steamRight.release()
            usesTouchpadInput = false
        }
        if usesCursorRegionInput {
            CursorRegionService.shared.endTracking()
            usesCursorRegionInput = false
        }

        // Cursor-guard goes idle: re-show the cursor if we hid it,
        // stop the recenter timer. Order matters: clear the preset
        // override AFTER the engine flag flips so the service has a
        // chance to undo its own state with the override still
        // active, then we discard the override.
        CursorGuardService.shared.engineDidChangeState(running: false)
        CursorGuardService.shared.clearPresetOverride()

        // Drop the power-source watcher; matched against the retain
        // call in start() so SystemStatsService can park its timer
        // when nothing else is observing.
        powerSourceSubscription?.cancel()
        powerSourceSubscription = nil
        lastSeenPowerSource = nil
        // Only a stop that follows a start holds a retain to give back.
        // stop() runs before every start and from many other places, and
        // releasing each time drove the count to zero under a running
        // preset, which silently ended power-source rate switching.
        if holdsSystemStats {
            SystemStatsService.shared.release()
            holdsSystemStats = false
        }

        // Drop any held MIDI notes so a key held at the moment the preset
        // stopped can't leave its binding latched on.
        MIDIInputService.shared.releaseAll()

        // Revert any preset light-bar override by re-asserting each
        // light-capable controller's stored slot color. setControllerLight
        // reads from `lightColors` / slot defaults, so the user-configured
        // general color comes back automatically.
        // Not gated on the engine's copy of the preset: the color can be
        // set from the visualizer while the preset runs, after this copy
        // was taken. Re-asserting the slot color is cheap either way.
        // Light bar outputs first: held colors let go and their rainbows
        // and standing colors undone, so the preset's own revert below
        // starts from the light the preset itself set up.
        releaseHeldLights()
        controllerService.endOutputLights()
        if controllerService.revertTemporaryLights() {
            log("Reverted light bar to general color")
        }

        activeStates.removeAll()
        rowActiveStates.removeAll()
        activeInputs.removeAll()
        faderBaseline.removeAll()
        faderEngaged.removeAll()
        activePreset = nil
        ExternalInputDeviceService.shared.setBlockedMouseButtons([])
        pollJoysticks = []
        pollDriveConfig = nil
        log("Engine stopped")
        // Final flush so the user sees the stop event in the log view.
        flushPendingLog()
    }

    // MARK: - Debug Logging

    /// The activity stream everyone sees: one plain line per thing that
    /// happened, always on (the raw PRESS / RELEASE debug lines stay behind
    /// the developer toggle). Repeats of the same row inside half a second
    /// are dropped so a stick held across the deadzone edge does not flood
    /// the log.
    private var lastActivityAt: [String: CFTimeInterval] = [:]
    private func activity(_ text: String, key: String? = nil, joystick: Int? = nil) {
        if let key {
            let now = CACurrentMediaTime()
            if let last = lastActivityAt[key], now - last < 0.5 { return }
            lastActivityAt[key] = now
        }
        ActivityLog.shared.event("Engine", text, slot: joystick)
    }

    private static func describe(_ outputs: [OutputAction]) -> String {
        outputs.isEmpty ? "nothing bound" : outputs.map(\.logName).joined(separator: " + ")
    }

    private func log(_ message: String, joystick: Int? = nil) {
        debugLineCount += 1
        let entry = "[\(debugLineCount)] \(message)"
        // Write to the internal buffer (no @Published trigger). The flush
        // timer copies this into `debugLog` at 5 Hz so observers of the
        // mapping engine do not re-render on every input event.
        pendingLog.append((text: entry, joystickIndex: joystick))
        pendingLogDirty = true
        if pendingLog.count > 50 {
            pendingLog.removeFirst()
        }
        // The same line goes to the app-wide activity log, classified so
        // the developer log can color and count it.
        let level: ActivityLog.Level
        let lower = message.lowercased()
        if lower.contains("fail") || lower.contains("error") || lower.contains("could not") {
            level = .error
        } else if lower.contains("no controller") || lower.contains("skipp") || lower.contains("missing") {
            level = .warning
        } else if message.contains("PRESS") || message.contains("RELEASE") || message.contains("Raw state") {
            level = .event
        } else {
            level = .info
        }
        ActivityLog.shared.post(level, "Engine", message, slot: joystick)
        #if DEBUG
        print("[MappingEngine] \(message)")
        #endif
    }

    /// Copy accumulated log entries into the @Published `debugLog` array.
    /// Only fires when there's something new and only at the timer's rate.
    ///
    /// Hard cap at 500 lines on the published mirror. `pendingLog` is
    /// capped at 50 between flushes but `debugLog` accumulates across
    /// engine sessions - without the cap it would grow unbounded as
    /// the user activates / deactivates presets across a long session.
    private func flushPendingLog() {
        guard pendingLogDirty, !pendingLog.isEmpty else { return }
        pendingLogDirty = false
        debugLog = pendingLog
        if debugLog.count > 500 {
            debugLog.removeFirst(debugLog.count - 500)
        }
    }

    // MARK: - Polling

    private var pollCount = 0

    /// Accumulated mouse motion delta for the current poll frame. Each
    /// continuous axis binding adds to this, and a single CGEvent is
    /// posted at the end of the poll. This produces true diagonal motion
    /// when, for example, a stick is pushed up-and-left and two separate
    /// bindings (X+ and Y-) both fire in the same frame.
    // Mouse motion accumulates as Float so slow, sub-pixel stick deflections
    // are not truncated to zero every frame. The whole-pixel part is posted at
    // flush and the fractional remainder is carried into the next frame, so a
    // gentle, precise stick still moves the cursor smoothly (important for fine
    // pointer control and accessibility).
    private var pendingMouseDeltaX: Float = 0
    private var pendingMouseDeltaY: Float = 0
    private var mouseCarryX: Float = 0
    private var mouseCarryY: Float = 0
    /// Gyro-driven pointer displacement this frame, in exact pixels (angle
    /// turned x gain). Handed to the pump at frame end, which pays it out
    /// smoothly without ever dropping any of it.
    private var pendingMotionDeltaX: Float = 0
    private var pendingMotionDeltaY: Float = 0
    /// Stick-driven pointer speed this frame, in pixels per 120 Hz frame.
    /// Handed to MouseMotionPump as a velocity at the end of the frame; the
    /// pump moves the pointer on its own timer, so the motion stays fluid
    /// when this poll runs late.
    private var pendingMouseRateX: Float = 0
    private var pendingMouseRateY: Float = 0
    /// Stick- and dial-driven scroll speed this frame, in scroll units per
    /// 120 Hz frame, handed to the pump like the pointer rate.
    private var pendingScrollRateX: Float = 0
    private var pendingScrollRateY: Float = 0

    /// When the previous poll frame ran, so analog motion can be scaled by
    /// the time that actually passed. Speed values are defined per 120 Hz
    /// frame; a late frame moves the cursor by the missed amount instead
    /// of stalling, and a fast one by proportionally less, so the pointer
    /// travels at a steady rate however the timer fires.
    private var lastFrameTime: Double = 0
    /// The factor for this frame: elapsed time over one 120 Hz frame,
    /// clamped so a long pause (sleep, a stalled main thread) cannot
    /// fling the cursor when polling resumes.
    private var frameScale: Float = 1

    /// Low-passed stick values, keyed by slot and axis. Stick sensors are
    /// noisy at the few-percent level and their values step rather than
    /// glide, which reaches the cursor as a fine shake and as robotic
    /// changes of pace. A short filter (about 25 ms) takes both out without
    /// a feel of lag; a full push still reaches full speed in a few frames.
    private var smoothedAxes: [Int: Float] = [:]
    /// When each smoothed axis was last updated, so a value left over from an
    /// earlier push is not filtered against.
    private var smoothedAt: [Int: CFTimeInterval] = [:]

    /// When each ramping stick row started moving the pointer, by binding.
    /// Cleared the frame the row goes quiet, so every new push starts slow.
    /// When each stick's push began, by group and stick ("0:1" is group 0's
    /// right stick); other inputs by row. Kept per stick, not per row: each
    /// half-axis row ramped on its own, so rolling the stick from right to
    /// up-right restarted the new direction at a fifth of its speed and bent
    /// the pointer's path. A key unused for a whole frame (the stick back
    /// inside its deadzone) is dropped, which restarts the ramp.
    private var rampStart: [String: CFTimeInterval] = [:]
    private var rampUsedThisFrame: Set<String> = []

    /// Ramp-up factor for a row with `rampMs`: 0.2 of full speed at the start
    /// of a push, easing to 1.0 once the stick has been held that long.
    private func rampFactor(for binding: BindingModel) -> Float {
        guard let ms = binding.rampMs, ms > 0 else { return 1 }
        let now = CACurrentMediaTime()
        let key = binding.input.type == .axis
            ? "\(pollingJoystickIndex):\(binding.input.index / 2)"
            : binding.id.uuidString
        rampUsedThisFrame.insert(key)
        let start: CFTimeInterval
        if let s = rampStart[key] { start = s } else { rampStart[key] = now; start = now }
        let t = min(1, (now - start) * 1000 / Double(ms))
        let eased = t * t * (3 - 2 * t)
        return Float(0.2 + 0.8 * eased)
    }


    /// A stable small number per motion channel, for the smoothing keys.
    private func channelIndex(_ channel: MotionChannel) -> Int {
        MotionChannel.allCases.firstIndex(of: channel) ?? 0
    }

    /// The smoothed value for one stick axis this frame.
    private func smoothedAxis(_ raw: Float, joystick: Int, axis: Int) -> Float {
        let key = joystick &* 256 &+ axis
        let now = CACurrentMediaTime()
        defer { smoothedAt[key] = now }
        // A value last filtered more than a few frames ago belongs to an
        // earlier push (the row went quiet in between), not to this one.
        // Filtering against it started every new push at the old speed.
        guard let previous = smoothedAxes[key],
              let at = smoothedAt[key], now - at < 0.05 else {
            smoothedAxes[key] = raw
            return raw
        }
        // Snap when the stick is let go or pushed the other way, so release
        // is instant and there is no glide through center.
        if raw == 0 || (raw > 0) != (previous > 0) {
            smoothedAxes[key] = raw
            return raw
        }
        // alpha = 1 - e^(-dt / tau), dt from frameScale (1 = 8.3 ms). A rising
        // value keeps the 25 ms filter that takes out sensor shake. A falling
        // one follows within a frame: easing off or letting go must slow the
        // pointer at once, or it runs past what it was aimed at.
        let dt = frameScale / 120
        let tau: Float = abs(raw) < abs(previous) ? 0.006 : 0.025
        let alpha = 1 - expf(-dt / tau)
        let value = previous + (raw - previous) * alpha
        smoothedAxes[key] = value
        return value
    }

    /// One-stick drive-mode engine (build 18). Holds gear/PWM/gesture state
    /// across poll frames; fed from the active preset's driveConfig.
    private let driveProcessor = DriveModeProcessor()
    /// Per-frame cache of controller states read by the binding loop, reused
    /// by the drive block so it doesn't re-read (and re-derive) the same slot.
    private var lastSlotState: [Int: ControllerState] = [:]
    /// The same frame's states keyed by the controller slot they were read
    /// from (a group can read another slot than its own index), for the
    /// emergency hold and drive mode, which ask by slot.
    private var stateByReadSlot: [Int: ControllerState] = [:]
    /// Throttled live mirror of drive telemetry for on-screen feedback.
    /// nil when drive mode is off / inactive.
    /// Drive telemetry lives on its own object: published on the engine, it
    /// re-rendered every view that observes the engine, the main window's
    /// root included, 15 times a second while a drive preset ran.
    var driveLiveState: DriveModeProcessor.LiveState? {
        get { DriveTelemetry.shared.state }
        set { DriveTelemetry.shared.state = newValue }
    }
    private var pendingScrollDeltaX: Float = 0
    private var pendingScrollDeltaY: Float = 0
    private var scrollCarryX: Float = 0
    private var scrollCarryY: Float = 0

    private func pollControllers() {
        guard activePreset != nil else { return }
        let preset = (joysticks: pollJoysticks, driveConfig: pollDriveConfig)
        pollCount += 1
        confirmMotionRecenter()
        // A Scan starting or ending in the editor is a pause edge: what the
        // pointer rows held is let go, latches made during the scan are
        // dropped, and the scanned control must come up before it fires.
        let pointerNow = pointerWhileEditing
        let scanGateNow = editorScanGate
        if pointerNow != lastPointerWhileEditing || scanGateNow != lastEditorScanGate {
            lastPointerWhileEditing = pointerNow
            lastEditorScanGate = scanGateNow
            ExternalInputDeviceService.shared.setBlockingPaused(outputsBlocked)
            CursorGuardService.shared.setSuspended(outputsBlocked)
            engineGeneration &+= 1
            clearLatches()
            InputSimulator.shared.releaseAll()
            releaseHeldLights()
            MouseMotionPump.shared.setVelocity(x: 0, y: 0)
            MouseMotionPump.shared.setScrollVelocity(x: 0, y: 0)
            holdBackHeldRows()
        }
        heldRowBlockedThisPoll = false
        defer { if requireSeenUp, !heldRowBlockedThisPoll { requireSeenUp = false } }
        // Cumulative session counter for the Stats panel - cheap UInt64
        // increment, ignored when the panel isn't subscribed.
        SystemStatsService.shared.recordControllerPolls()
        pendingMouseDeltaX = 0
        pendingMouseDeltaY = 0
        pendingMotionDeltaX = 0
        pendingMotionDeltaY = 0
        pendingScrollDeltaX = 0
        pendingScrollDeltaY = 0
        pendingMouseRateX = 0
        pendingMouseRateY = 0
        pendingScrollRateX = 0
        pendingScrollRateY = 0

        // Hoist time-source reads out of the per-binding inner loop.
        // CACurrentMediaTime is a monotonic Double seconds counter with
        // no allocation cost; replaces the Date() that used to be
        // constructed per turbo binding per poll frame.
        let nowMonotonic = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = Float(nowMonotonic - lastFrameTime)
            frameScale = max(0.25, min(4, dt * 120))
        } else {
            frameScale = 1
        }
        lastFrameTime = nowMonotonic
        // The raw-state log line and the published-active-inputs flush
        // also wanted a Date(), but they only fire infrequently so we
        // build one lazily inside those branches.
        let shouldLogRawState = (pollCount % 120 == 1)

        lastSlotState.removeAll(keepingCapacity: true)
        stateByReadSlot.removeAll(keepingCapacity: true)
        oneShotFrame.removeAll(keepingCapacity: true)
        // Refresh the group-to-controller map twice a second.
        slotResolveTick += 1
        if slotResolveTick >= 60 || slotForGroup.isEmpty {
            slotResolveTick = 0
            let resolved = controllerService.effectiveSlots(for: preset.joysticks)
            // The touchpad feed follows the first group that reads a touchpad.
            let touchTypes: Set<InputType> = [.touchpad, .touchpadRegion, .touchpadGesture]
            // Only a slot that has a touchpad: a touch-only group left on an
            // empty slot made that slot the source and every touch dropped.
            // Rows on a Steam Controller's left pad (surface 1) do not
            // compete for the main surface, so they do not pick its source,
            // and a Steam pad's right-pad rows have a surface of their own.
            let touchGroups = preset.joysticks.indices.filter { i in
                preset.joysticks[i].bindings.contains { touchTypes.contains($0.input.type) && $0.input.touchpadSurface != 1 }
            }
            let touchSlot = touchGroups.lazy.compactMap { resolved[$0] }
                .first { self.controllerService.controllerDetails[$0]?.hasTouchpad == true && !self.controllerService.isSteamSlot($0) }
            let steamSlot = touchGroups.lazy.compactMap { resolved[$0] }.first { self.controllerService.isSteamSlot($0) }
            if controllerService.touchpadSteamSourceSlot != steamSlot {
                if controllerService.touchpadSteamSourceSlot != nil { TouchpadService.steamRight.touchSourceDisconnected() }
                controllerService.touchpadSteamSourceSlot = steamSlot
            }
            steamTouchGroups = steamSlot.map { slot in Set(preset.joysticks.indices.filter { resolved[$0] == slot }) }
            if controllerService.touchpadSourceSlot != touchSlot {
                // The old source's finger is let go: its lift would now be
                // rejected, and a zone it held stayed pressed.
                if controllerService.touchpadSourceSlot != nil { TouchpadService.shared.touchSourceDisconnected() }
                controllerService.touchpadSourceSlot = touchSlot
            }
            touchpadGroups = touchSlot.map { slot in Set(preset.joysticks.indices.filter { resolved[$0] == slot }) }
            // The second surface the same way: the first group with left
            // pad rows picks the Steam Controller that feeds it, so two
            // players' left pads do not drive each other's rows.
            let secondGroups = preset.joysticks.indices.filter { i in
                preset.joysticks[i].bindings.contains { touchTypes.contains($0.input.type) && $0.input.touchpadSurface == 1 }
            }
            let secondSlot = secondGroups.lazy.compactMap { resolved[$0] }
                .first { self.controllerService.controllerDetails[$0]?.hasTouchpad == true }
            if controllerService.touchpadSecondSourceSlot != secondSlot {
                if controllerService.touchpadSecondSourceSlot != nil { TouchpadService.second.touchSourceDisconnected() }
                controllerService.touchpadSecondSourceSlot = secondSlot
            }
            secondTouchGroups = secondSlot.map { slot in Set(preset.joysticks.indices.filter { resolved[$0] == slot }) }
            for index in preset.joysticks.indices {
                let slot = resolved[index] ?? index
                if slot != index, loggedSlotRedirect[index] != slot {
                    loggedSlotRedirect[index] = slot
                    if slot == GameControllerService.noSlot {
                        log("Input device \(index) is waiting for \(preset.joysticks[index].customName ?? "its controller") to connect",
                            joystick: index)
                    } else {
                        log("Input device \(index) is reading \(controllerService.controllerName(at: slot)) in slot \(slot)",
                            joystick: index)
                    }
                }
            }
            slotForGroup = resolved
        }

        // One read per controller per frame: a read drains the gyro, so a
        // second group on the same pad got an empty accumulator and no motion.
        var frameStates: [Int: ControllerState] = [:]
        for (joystickIndex, joystickMapping) in preset.joysticks.enumerated() {
            // External-only bindings can fire even without a controller, so
            // we don't bail out when the slot is empty - we just skip the
            // controller-side checks for that binding.
            // Which controller this group reads. Resolved every half second
            // rather than every frame: the answer only changes when a
            // controller connects or the user picks a different device.
            let readSlot = slotForGroup[joystickIndex] ?? joystickIndex
            var state = frameStates[readSlot] ?? controllerService.readControllerState(at: readSlot)
            if let state { stateByReadSlot[readSlot] = state; frameStates[readSlot] = state }
            if dpadOneWay, let hats = state?.hats, !hats.isEmpty {
                state?.hats = oneDirectionHats(hats, group: joystickIndex)
            }
            if let state { lastSlotState[joystickIndex] = state }

            // Log raw state once per second for debugging. The .filter +
            // .map + String(format:) chain allocates several arrays per
            // call - now gated behind both the 1Hz cadence AND the
            // debugEnabled flag so it's free when the user has the
            // panel collapsed.
            if shouldLogRawState && debugEnabled, let state = state {
                let activeButtons = state.buttons.filter { $0.value > 0.5 }.map { "btn\($0.key)" }
                let activeAxes = state.axes.filter { abs($0.value) > defaultAxisThreshold }.map { "axi\($0.key)=\(String(format: "%.2f", $0.value))" }
                if !activeButtons.isEmpty || !activeAxes.isEmpty {
                    log("Raw state J\(joystickIndex): \(activeButtons + activeAxes)", joystick: joystickIndex)
                }
            }

            // Reuse the scratch set instead of allocating a fresh
            // Set<String> every joystick every poll frame.
            scratchActiveSet.removeAll(keepingCapacity: true)
            scratchRowActiveSet.removeAll(keepingCapacity: true)

            // Pre-pass: which plain inputs a held chord claims this frame,
            // and whether a gyro-ratchet row is held. Both must be known
            // before any row fires, so the order of rows does not matter.
            chordClaimed.removeAll(keepingCapacity: true)
            chordSatisfied.removeAll(keepingCapacity: true)
            currentSlotMotionMuted = false
            // Set first: touchpad inputs are read only for the group that
            // reads the touchpad, and the pre-pass read them as the group
            // polled last.
            pollingJoystickIndex = joystickIndex
            for b in joystickMapping.bindings {
                let mods = b.modifiers
                if !mods.isEmpty,
                   mods.allSatisfy({ inputIsActive($0, state: state, binding: nil) }),
                   inputIsActive(b.input, state: state, binding: b) {
                    chordClaimed.insert(cachedKey(for: b))
                    chordSatisfied[cachedKey(for: b), default: []].append(Set(mods.map(\.serialized)))
                }
            }
            // A Pause Motion row honors its own chord, and a plain one stays
            // quiet while a chord holds its input.
            for b in joystickMapping.bindings where !currentSlotMotionMuted
                && b.outputs.contains(where: { $0.type == .appAction && $0.appActionKind == .holdMuteMotion }) {
                let mods = b.modifiers
                guard inputIsActive(b.input, state: state, binding: b) else { continue }
                if mods.isEmpty ? !chordClaimed.contains(cachedKey(for: b))
                    : mods.allSatisfy({ inputIsActive($0, state: state, binding: nil) }) {
                    currentSlotMotionMuted = true
                    // The ratchet: wherever the controller is let go is the
                    // new neutral. Motion rows read nothing while it is held,
                    // so the anchor moves here, not where a row fires.
                    pitchAnchorReset = true
                }
            }

            for binding in joystickMapping.bindings {
                let plainKey = cachedKey(for: binding)
                // bindKey is keyed by binding UUID so two distinct
                // bindings on the same physical input (e.g. one toggle,
                // one turbo, or two different macros) don't share
                // toggleStates / turboTimestamps entries or a press edge.
                // Every row gets one: plain rows name the keys they hold
                // with it (so two rows holding W keep it down until both
                // let go), hold and double-tap rows keep their timers under
                // it, and the activity log tells rows apart by it. Cached,
                // so the 120 Hz loop does not allocate a uuidString per row
                // per frame.
                let bindKey: String
                if let cached = bindKeyCache[binding.id] {
                    bindKey = cached
                } else {
                    let k = "\(joystickIndex):\(binding.id.uuidString)"
                    bindKeyCache[binding.id] = k
                    bindKey = k
                }
                hysteresisActive = rowActiveStates[joystickIndex]?.contains(bindKey) ?? false
                var isActive = inputIsActive(binding.input, state: state, binding: binding)
                hysteresisActive = false
                let inputKey: String
                let rowModifiers = binding.modifiers
                if !rowModifiers.isEmpty {
                    // Chord row: every held control must be down too, and it
                    // tracks its own press state so it never shares an edge
                    // with the plain row.
                    if isActive {
                        isActive = rowModifiers.allSatisfy { inputIsActive($0, state: state, binding: nil) }
                    }
                    // A satisfied chord holding more controls on the same
                    // input wins: LB + RB + A, not also LB + A.
                    if isActive, let others = chordSatisfied[plainKey], others.count > 1 {
                        let mine = Set(rowModifiers.map(\.serialized))
                        if others.contains(where: { $0.isStrictSuperset(of: mine) }) { isActive = false }
                    }
                    if let k = chordKeyCache[binding.id] {
                        inputKey = k
                    } else {
                        let k = plainKey + "+" + rowModifiers.map(\.serialized).joined(separator: "+")
                        chordKeyCache[binding.id] = k
                        inputKey = k
                    }
                } else {
                    inputKey = plainKey
                    if isActive, chordClaimed.contains(plainKey) {
                        chordLatched[joystickIndex, default: []].insert(plainKey)
                        isActive = false
                    } else if isActive, chordLatched[joystickIndex]?.contains(plainKey) == true {
                        isActive = false   // still held since the chord
                    } else if !isActive {
                        chordLatched[joystickIndex]?.remove(plainKey)
                    }
                }
                // A row that switches presets (Next Preset, Activate Preset)
                // and was already held when this preset started waits for its
                // control to come up first: otherwise each preset it switched
                // to saw the same held button as a new press, and one tap
                // stepped through the folder about ten times.
                if appActionRow(binding) {
                    if !isActive { armedAppActionRows.insert(bindKey) }
                    else if !armedAppActionRows.contains(bindKey) { isActive = false }
                }
                if requireSeenUp {
                    if !isActive { rowsSeenUp.insert(bindKey) }
                    else if !rowsSeenUp.contains(bindKey) {
                        if Self.waitsForRelease(binding) { isActive = false; heldRowBlockedThisPoll = true }
                        else { rowsSeenUp.insert(bindKey) }
                    }
                }
                if isActive {
                    scratchActiveSet.insert(inputKey)
                    scratchRowActiveSet.insert(bindKey)
                }

                let wasActive = rowActiveStates[joystickIndex]?.contains(bindKey) ?? false
                // Axis-driven MIDI CC / pitch-bend must never fire on the press
                // or release edge - that spikes the value for one frame and
                // slams it on release. fireOutputs suppresses those two output
                // types when this is true; the continuous path handles them.
                let inputIsAxis = binding.input.type == .axis

                if binding.toggleMode == true {
                    // Toggle mode: press toggles on/off
                    if isActive && !wasActive {
                        let isToggledOn = toggleStates[bindKey] ?? false
                        if isToggledOn {
                            if debugEnabled { log("TOGGLE OFF: \(inputKey)", joystick: joystickIndex) }
                            fireOutputs(binding.outputs, press: false, inputIsAxis: inputIsAxis, owner: bindKey,
                                        restingCCValue: binding.input.axisDirection == nil ? 64 : 0)
                            // A toggled auto clicker buzzes when it stops as
                            // well as when it starts, so a hand on the pad
                            // feels the run end.
                            if binding.turboEnabled == true { fireFeedback(for: binding, joystickIndex: joystickIndex) }
                            // Toggling a macro row off stops its chain; it ran
                            // on to the end, and the next press started nothing.
                            if binding.macroSteps?.isEmpty == false, macrosInFlight.contains(bindKey) {
                                macroCancelRequests.insert(bindKey)
                            }
                            toggleStates[bindKey] = false
                        } else {
                            if debugEnabled {
                                log("TOGGLE ON: \(inputKey) -> \(binding.outputs.map(\.logName))", joystick: joystickIndex)
                            }
                            // A macro binding with Toggle enabled fires its
                            // chain on the ON transition. The toggle branch
                            // used to consult only binding.outputs, so the
                            // documented "Toggle + Macro" combination
                            // silently did nothing.
                            if let steps = binding.macroSteps, !steps.isEmpty {
                                if !macrosInFlight.contains(bindKey) {
                                    macrosInFlight.insert(bindKey)
                                    macroCancelRequests.remove(bindKey)
                                    executeMacro(steps, joystickIndex: joystickIndex, bindKey: bindKey,
                                                 repeatCount: binding.repeatCount ?? 1,
                                                 repeatDelayMs: binding.repeatDelayMs ?? 100)
                                }
                            } else if binding.turboEnabled != true {
                                fireOutputs(binding.outputs, press: true, inputIsAxis: inputIsAxis, owner: bindKey)
                            }
                            // An auto-click (toggle plus turbo) leaves its first
                            // press to turboTick below, in this same frame;
                            // pressing here too sent it twice (two scroll steps,
                            // text typed twice, Stop after N sending N + 1).
                            toggleStates[bindKey] = true
                            activity("\(binding.input.displayName) toggled on \u{2192} \(Self.describe(binding.outputs))", joystick: joystickIndex)
                            fireFeedback(for: binding, joystickIndex: joystickIndex)
                        }
                    }
                    // Keep firing continuous outputs while toggled on
                    if toggleStates[bindKey] == true,
                       let s = state ?? (Self.readsNoSlot(binding.input.type) ? Self.detachedState : nil) {
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                    }
                    // Toggle plus turbo is an auto-clicker: one press starts
                    // the repeating run, the next press (or the press limit)
                    // stops it. A macro takes the row over, so it never
                    // repeats beside the macro.
                    if binding.turboEnabled == true, binding.macroSteps?.isEmpty != false {
                        if toggleStates[bindKey] == true {
                            if !turboTick(binding, bindKey: bindKey, inputIsAxis: inputIsAxis, now: nowMonotonic) {
                                toggleStates[bindKey] = false
                                turboTimestamps.removeValue(forKey: bindKey)
                                turboCounts.removeValue(forKey: bindKey)
                            }
                        } else if turboTimestamps[bindKey] != nil {
                            turboTimestamps.removeValue(forKey: bindKey)
                            turboCounts.removeValue(forKey: bindKey)
                        }
                    }
                } else if binding.turboEnabled == true, binding.macroSteps?.isEmpty != false {
                    // Turbo mode: rapid fire while held. A row with a macro
                    // runs the macro below instead.
                    if isActive {
                        if !wasActive {
                            if debugEnabled {
                                log("TURBO START: \(inputKey) -> \(binding.outputs.map(\.logName))", joystick: joystickIndex)
                            }
                            fireFeedback(for: binding, joystickIndex: joystickIndex)
                        }
                        _ = turboTick(binding, bindKey: bindKey, inputIsAxis: inputIsAxis, now: nowMonotonic)
                        if let s = state ?? (Self.readsNoSlot(binding.input.type) ? Self.detachedState : nil) {
                            fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                        }
                    } else if wasActive {
                        if debugEnabled { log("TURBO END: \(inputKey)", joystick: joystickIndex) }
                        fireOutputs(binding.outputs, press: false, inputIsAxis: inputIsAxis, owner: bindKey,
                                        restingCCValue: binding.input.axisDirection == nil ? 64 : 0)
                        turboTimestamps.removeValue(forKey: bindKey)
                        turboCounts.removeValue(forKey: bindKey)
                    }
                } else {
                    // Normal mode
                    let usesDeferred = binding.macroSteps?.isEmpty != false
                        && (binding.holdOutputs != nil || binding.doubleTapOutputs != nil)
                    if isActive && !wasActive {
                        StatsService.shared.recordButtonPress(inputKey: inputKey)
                        if debugEnabled {
                            log("PRESS: \(inputKey) -> \(binding.outputs.map(\.logName))", joystick: joystickIndex)
                        }
                        // Motion and touchpad rows are continuous; their edges
                        // are not events anyone wants a line for.
                        if binding.input.type != .motion, binding.input.type != .touchpad {
                            let what: String
                            if let steps = binding.macroSteps, !steps.isEmpty {
                                what = "macro, \(steps.count) steps"
                            } else if binding.holdOutputs != nil || binding.doubleTapOutputs != nil {
                                what = "tap: " + Self.describe(binding.outputs)
                            } else {
                                what = Self.describe(binding.outputs)
                            }
                            activity("\(binding.input.displayName) \u{2192} \(what)", key: bindKey, joystick: joystickIndex)
                        }
                        // Check for macro. Guard against a re-press
                        // while the previous macro chain is still in
                        // flight - previously this kicked off a fresh
                        // executeMacro on every press transition,
                        // running the chain twice in parallel and
                        // duplicating every output event. Now the
                        // second press is ignored until the first
                        // chain finishes (it bumps macrosInFlight).
                        if let steps = binding.macroSteps, !steps.isEmpty {
                            if !macrosInFlight.contains(bindKey) {
                                macrosInFlight.insert(bindKey)
                                macroCancelRequests.remove(bindKey)
                                executeMacro(steps, joystickIndex: joystickIndex, bindKey: bindKey,
                                             repeatCount: binding.repeatCount ?? 1,
                                             repeatDelayMs: binding.repeatDelayMs ?? 100)
                            }
                        } else if usesDeferred {
                            // Tap-vs-hold / double-tap: record the press and
                            // defer the decision to the hold threshold check
                            // below or the release handler.
                            deferredPressStart[bindKey] = nowMonotonic
                            // A second press inside the double-tap window is
                            // the double tap's second half, however long it
                            // is held: the pending single is called off now,
                            // not left to fire while the button is down.
                            if binding.doubleTapOutputs != nil, let last = lastTapTime[bindKey],
                               nowMonotonic - last <= Double(max(100, min(2000, binding.doubleTapWindowMs ?? 300))) / 1000.0 {
                                pendingSingleTapToken[bindKey, default: 0] += 1
                                secondTapPressed.insert(bindKey)
                            }
                            if Self.isModifierKeyInput(binding.input) {
                                modifierKeyDownMark[bindKey] = Self.keyDownEventCount()
                            }
                        } else if (binding.repeatCount ?? 1) > 1 {
                            fireWithRepeat(binding, bindKey: bindKey)
                        } else {
                            fireOutputs(binding.outputs, press: true, inputIsAxis: inputIsAxis, owner: bindKey,
                                        repeats: binding.keyRepeat == true)
                            if Self.isOneShot(binding.input) { nudgePointer(for: binding.outputs, owner: bindKey) }
                        }
                        fireFeedback(for: binding, joystickIndex: joystickIndex)
                    } else if isActive, usesDeferred,
                              !holdFired.contains(bindKey),
                              let hold = binding.holdOutputs,
                              let start = deferredPressStart[bindKey],
                              nowMonotonic - start >= Double(max(50, min(5000, binding.holdThresholdMs ?? 300))) / 1000.0,
                              !otherKeyPressedDuringModifier(bindKey) {
                        // Held past the threshold: this press is the HOLD
                        // action. It stays pressed until the input releases.
                        holdFired.insert(bindKey)
                        // A tap then a press held long: the first tap's
                        // single action, called off when this press began,
                        // still goes out ahead of the hold.
                        if secondTapPressed.contains(bindKey) {
                            lastTapTime.removeValue(forKey: bindKey)
                            pulse(binding.outputs, bindKey: bindKey)
                        }
                        if debugEnabled { log("HOLD: \(inputKey)", joystick: joystickIndex) }
                        activity("\(binding.input.displayName) held \u{2192} \(Self.describe(hold))", joystick: joystickIndex)
                        // A discrete action, like the tap: on a stick or
                        // trigger the axis flag sent a hold's MIDI CC or pitch
                        // bend nothing on press and only its rest value later.
                        fireOutputs(hold, press: true, inputIsAxis: false, owner: bindKey + "#hold",
                                    repeats: binding.keyRepeat == true)
                    } else if isActive, usesDeferred, holdFired.contains(bindKey),
                              let hold = binding.holdOutputs,
                              hold.contains(where: { $0.type == .mouseMotion || $0.type == .mouseWheel }),
                              let s = state ?? (Self.readsNoSlot(binding.input.type) ? Self.detachedState : nil) {
                        // A held action that moves the pointer or scrolls
                        // keeps doing it every poll while the hold lasts, as
                        // a main action does: the hold is a second action of
                        // its own, not only a key.
                        fireContinuousOutputs(hold.filter { $0.type == .mouseMotion || $0.type == .mouseWheel },
                                              input: binding.input, state: s, binding: binding)
                    } else if !isActive && wasActive {
                        if debugEnabled { log("RELEASE: \(inputKey)", joystick: joystickIndex) }
                        if usesDeferred {
                            handleDeferredRelease(binding, bindKey: bindKey, now: nowMonotonic)
                        } else if binding.macroSteps?.isEmpty != false && (binding.repeatCount ?? 1) <= 1 {
                            fireOutputs(binding.outputs, press: false, inputIsAxis: inputIsAxis, owner: bindKey,
                                        restingCCValue: binding.input.axisDirection == nil ? 64 : 0)
                        }
                        // Stop-on-release: letting go asks the running chain
                        // to halt at its next press hop and release held steps.
                        if binding.macroSteps?.isEmpty == false,
                           binding.macroInterruptOnRelease == true,
                           macrosInFlight.contains(bindKey) {
                            macroCancelRequests.insert(bindKey)
                        }
                    } else if isActive, !usesDeferred,
                              let s = state ?? (Self.readsNoSlot(binding.input.type) ? Self.detachedState : nil) {
                        // Deferred bindings skip continuous firing: which
                        // action this press means is not decided yet.
                        // MIDI bindings pass an empty controller state:
                        // their analog value comes from midiAxisValue, so
                        // a dial keeps scrolling with no gamepad attached.
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                    } else if !isActive, !usesDeferred,
                              binding.outputs.contains(where: { $0.type == .absoluteVolume }),
                              let s = state ?? (Self.readsNoSlot(binding.input.type) ? Self.detachedState : nil) {
                        // Fader outputs follow the control's position even
                        // while the binding reads "inactive": a knob at 20%
                        // is below every press threshold but the volume
                        // should still be 20%.
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                    }
                }
            }

            // Copy out into activeStates (cheap Set copy) so the
            // scratch can be reused next iteration.
            activeStates[joystickIndex] = scratchActiveSet
            rowActiveStates[joystickIndex] = scratchRowActiveSet
        }

        // The kill switch. Runs after the binding loop so it can reuse the
        // controller state already read this frame; it stays independent of
        // what the preset maps that button to.
        checkEmergencyHold(now: nowMonotonic)
        // The emergency stop (or a row's app action) may have stopped the
        // engine inside this frame. The rest of the frame ran on its local
        // copy and pressed the drive throttle again after the stop.
        guard isRunning else { return }
        // A stick not pushed this frame starts its ramp over next time.
        if !rampStart.isEmpty {
            rampStart = rampStart.filter { rampUsedThisFrame.contains($0.key) }
        }
        rampUsedThisFrame.removeAll(keepingCapacity: true)

        // One-stick drive mode (build 18). Runs after the binding loops so
        // its analog steering rides the same per-frame mouse flush below.
        // Releases every held key whenever drive is off or outputs pause.
        if let drive = preset.driveConfig, drive.enabled, !outputsBlocked {
            // Reuse the slot state already read by the binding loop when the
            // drive slot is one of the polled joysticks; only read again if the
            // drive slot sits outside that range.
            let dstate = stateByReadSlot[drive.slot] ?? controllerService.readControllerState(at: drive.slot)
            // No controller in the drive slot: nothing is held, rather than
            // the coast brake tapping S into whatever app is in front.
            let ax = dstate?.axes[drive.steerAxis] ?? 0
            let ay = dstate?.axes[drive.throttleAxis] ?? 0
            if dstate == nil {
                driveProcessor.releaseAll()
                if driveLiveState != nil { driveLiveState = nil }
            } else {
            // Steering is a speed per 120 Hz frame, like stick rows: as a
            // rate it goes through the pump with both Pointer speed sliders,
            // and no longer steers faster or slower with the poll rate.
            pendingMouseRateX += driveProcessor.process(drive, axisX: ax, axisY: ay, now: nowMonotonic)
            // Publish live telemetry at ~15 Hz so the editor's drive readout
            // can show gear / throttle without churning the UI at 120 Hz.
            if pollCount % 8 == 0 {
                let s = driveProcessor.liveState
                if driveLiveState != s { driveLiveState = s }
            }
            }
        } else {
            driveProcessor.releaseAll()
            if driveLiveState != nil { driveLiveState = nil }
        }

        // Flush accumulated mouse and scroll deltas as a single CGEvent.
        // Skipped while outputsPaused so the editor can stay open over an
        // active touchpad-mouse preset without the cursor flying around.
        // (Deltas themselves are zeroed at the start of every frame.)
        if !outputsBlocked || pointerOnly {
            // The two Speed multipliers, Settings' and the preset's, apply
            // here, at the one place every pointer movement passes through.
            // Neither was read anywhere before: both sliders were inert.
            let gain = pointerGain
            let scrollGain = scrollGainCache
            // Stick speed is per 120 Hz frame; the pump wants pixels per second.
            MouseMotionPump.shared.setVelocity(x: pendingMouseRateX * 120 * gain, y: pendingMouseRateY * 120 * gain)
            MouseMotionPump.shared.addDisplacement(x: pendingMotionDeltaX * gain, y: pendingMotionDeltaY * gain)
            MouseMotionPump.shared.setScrollVelocity(x: pendingScrollRateX * 120 * scrollGain,
                                                     y: pendingScrollRateY * 120 * scrollGain)
            let pumped = MouseMotionPump.shared.takeMovedPixels()
            if pumped > 0 { StatsService.shared.recordMouseMotion(pixels: pumped) }
            let scrolled = MouseMotionPump.shared.takeScrolledUnits()
            if scrolled > 0 { StatsService.shared.recordScroll(ticks: scrolled) }
            // Convert the Float accumulator to whole pixels and carry the
            // fractional remainder into the next frame so slow motion is smooth.
            let totalX = pendingMouseDeltaX + mouseCarryX
            let totalY = pendingMouseDeltaY + mouseCarryY
            // Clamp before Int(): a malformed / imported preset with an absurd
            // speed could push the accumulator past Int range (a hard trap) or
            // to NaN. Normal deltas are a few pixels, far below this budget.
            let clampedX = totalX.isFinite ? max(-100_000, min(100_000, totalX)) : 0
            let clampedY = totalY.isFinite ? max(-100_000, min(100_000, totalY)) : 0
            let wholeX = Int(clampedX)
            let wholeY = Int(clampedY)
            mouseCarryX = clampedX - Float(wholeX)
            mouseCarryY = clampedY - Float(wholeY)
            if wholeX != 0 || wholeY != 0 {
                InputSimulator.shared.moveMouse(deltaX: wholeX, deltaY: wholeY)
                StatsService.shared.recordMouseMotion(pixels: abs(wholeX) + abs(wholeY))
            }
            // Whole-pixel scroll with the fraction carried, exactly like the
            // cursor path: no dead band at low deflection, and fewer,
            // larger events instead of one single-pixel event per frame.
            let scrollX = pendingScrollDeltaX * scrollGain + scrollCarryX
            let scrollY = pendingScrollDeltaY * scrollGain + scrollCarryY
            let wholeScrollX = Int32(max(-100_000, min(100_000, scrollX.isFinite ? scrollX : 0)))
            let wholeScrollY = Int32(max(-100_000, min(100_000, scrollY.isFinite ? scrollY : 0)))
            scrollCarryX = scrollX - Float(wholeScrollX)
            scrollCarryY = scrollY - Float(wholeScrollY)
            if wholeScrollX != 0 || wholeScrollY != 0 {
                InputSimulator.shared.scrollWheel(deltaX: wholeScrollX, deltaY: wholeScrollY)
                StatsService.shared.recordScroll(ticks: Int(abs(wholeScrollX) + abs(wholeScrollY)))
            }
        }

        // Drain the touchpad per-frame deltas exactly once, after every binding
        // has read them via peekDelta. This lets two bindings on the same finger
        // and axis both see the motion (the old consumeDelta zeroed it on the
        // first read, so the second got 0). Unconditional so deltas can't pile
        // up and fling the cursor when outputs resume after a pause.
        TouchpadService.shared.endFrame()
        TouchpadService.second.endFrame()
        TouchpadService.steamRight.endFrame()
        updateIdlePolling(now: nowMonotonic)

        // Update active inputs for UI highlighting. Reuse the scratch
        // set so the union doesn't allocate a fresh container every
        // poll frame.
        scratchAllActiveSet.removeAll(keepingCapacity: true)
        for (_, states) in activeStates {
            scratchAllActiveSet.formUnion(states)
        }
        if scratchAllActiveSet != activeInputs {
            activeInputs = scratchAllActiveSet
        }
        // Mirror to the @Published copy at most 10 Hz so the highlighted row in
        // the editor doesn't trigger a full sheet re-render on every poll frame.
        // This is a trailing reconcile, not gated on a change this frame, so a
        // change that was throttled out still converges within ~0.1s instead of
        // leaving the published mirror permanently stale. Uses the monotonic
        // clock already captured at the top of pollControllers.
        if activeInputsPublished != activeInputs,
           nowMonotonic - activeInputsLastFlush > 0.1 {
            activeInputsLastFlush = nowMonotonic
            activeInputsPublished = activeInputs
        }

        // Drain external motion / scroll deltas now that bindings have read
        // them. Buttons and held keys stay sticky until released.
        externalMouseDX.removeAll(keepingCapacity: true)
        externalMouseDY.removeAll(keepingCapacity: true)
        externalScrollDX.removeAll(keepingCapacity: true)
        externalScrollDY.removeAll(keepingCapacity: true)
    }

    /// One answer for "is this control down right now", whatever device
    /// it lives on. Keyboard, mouse, and MIDI inputs fire with no game
    /// controller connected; controller inputs need the slot's state.
    private func inputIsActive(_ input: InputEvent, state: ControllerState?, binding: BindingModel?) -> Bool {
        // One-shot inputs are used up when read. Read each once per frame and
        // share the answer, so the chord pre-pass does not eat a Program
        // Change before its row sees it, and two rows on the same one fire.
        if Self.isOneShot(input) {
            // The touchpad group gate before the shared answer: a gesture
            // one group read (and used up) fired the other group's row too.
            if input.type == .touchpadGesture, let groups = touchGate(input.touchpadSurface),
               !groups.contains(pollingJoystickIndex) { return false }
            let key = cachedKey(forInput: input)
            if let seen = oneShotFrame[key] { return seen }
            let result = readInput(input, state: state, binding: binding)
            oneShotFrame[key] = result
            return result
        }
        return readInput(input, state: state, binding: binding)
    }

    /// A one-shot input (a Turn knob step, a tap on the Mac, a touchpad
    /// gesture) is active for a single frame, which continuous pointer and
    /// scroll outputs never saw, so they did nothing. Each step moves or
    /// scrolls once instead: a wheel notch, or a nudge of the row's speed.
    private func nudgePointer(for outputs: [OutputAction], owner: String) {
        guard !outputsBlocked || (pointerOnly && !touchpadHeldBack(owner: owner)) else { return }
        for output in outputs {
            let sign = output.resolvedMouseDirection == .positive ? 1 : -1
            switch output.type {
            case .mouseWheel:
                InputSimulator.shared.scrollWheelStep(axis: output.resolvedMouseAxis,
                                                      direction: output.resolvedMouseDirection,
                                                      lines: Int(scrollGainCache.rounded()))
            case .mouseMotion:
                let distance = sign * max(1, output.speed ?? 6) * 4
                if output.resolvedMouseAxis == .horizontal {
                    InputSimulator.shared.moveMouse(deltaX: distance, deltaY: 0)
                } else {
                    InputSimulator.shared.moveMouse(deltaX: 0, deltaY: distance)
                }
            default:
                break
            }
        }
    }

    /// Answers for one-shot inputs this frame; cleared at each frame start.
    private var oneShotFrame: [String: Bool] = [:]

    private static func isOneShot(_ input: InputEvent) -> Bool {
        switch input.type {
        case .touchpadGesture, .chassisTap: return true
        case .midi:
            switch input.midiKind ?? .note {
            case .programChange, .transport: return true
            case .cc: return input.midiCCMode == .relative
            default: return false
            }
        default: return false
        }
    }

    /// The per-frame answer cache key. A relative CC row's Turn step is not
    /// part of `serialized`, so two Turn rows on the same CC with different
    /// steps shared one answer and the second step never applied.
    private func cachedKey(forInput input: InputEvent) -> String {
        if input.type == .midi, input.midiCCMode == .relative, let step = input.midiTurnStep {
            return input.serialized + " step \(step)"
        }
        // A Steam pad's right trackpad is its own instance: its taps are
        // not the PlayStation touchpad's, though the rows read the same.
        if input.type == .touchpadGesture, input.touchpadSurface != 1, pollingSteamGroup {
            return input.serialized + " steam"
        }
        return input.serialized
    }

    private func readInput(_ input: InputEvent, state: ControllerState?, binding: BindingModel?) -> Bool {
        // Each surface answers only the groups on the pad that feeds it.
        if [.touchpad, .touchpadRegion, .touchpadGesture].contains(input.type) {
            // A group whose pinned controller is away claims no surface, as
            // it claims no buttons.
            if slotForGroup[pollingJoystickIndex] == GameControllerService.noSlot { return false }
            if let groups = touchGate(input.touchpadSurface), !groups.contains(pollingJoystickIndex) { return false }
        }
        switch input.type {
        case .extKey, .extMouse:
            return checkExternalInput(input)
        case .midi:
            return checkMIDIInput(input, binding: binding,
                                  threshold: binding?.deadzone ?? defaultAxisThreshold)
        default:
            if let s = state {
                return checkInput(input, state: s, binding: binding)
            }
            // These read their own service rather than a controller slot, so
            // they have to keep firing when no controller is connected at all
            // (a trackpad-only or tap-only preset is perfectly valid). Every
            // other type genuinely needs the slot's state.
            switch input.type {
            case .touchpad, .touchpadRegion, .touchpadGesture, .cursorRegion, .chassisTap:
                return checkInput(input, state: Self.detachedState, binding: binding)
            default:
                return false
            }
        }
    }

    /// Stand-in slot state for inputs that never read the controller.
    private static let detachedState = ControllerState()
    /// Inputs that do not come from a controller slot (MIDI, the Mac's
    /// keyboard and mouse, regions, taps, the touchpad feed). Their pointer
    /// and scroll outputs run with no controller in the group's slot.
    private static func readsNoSlot(_ type: InputType) -> Bool {
        switch type {
        case .midi, .extKey, .extMouse, .cursorRegion, .chassisTap,
             .touchpad, .touchpadRegion, .touchpadGesture: return true
        default: return false
        }
    }

    /// Holding the panic button on ANY connected controller for the
    /// configured time stops everything. Deliberately independent of the
    /// preset's bindings: if a preset has taken over the keyboard and mouse,
    /// the controller in your hands has to be a way out.
    private func checkEmergencyHold(now: TimeInterval) {
        let service = EmergencyStopService.shared
        guard service.controllerHoldEnabled else {
            panicHoldStart = nil
            return
        }
        guard emergencyHoldIsDown(useFrame: true) else {
            panicHoldStart = nil
            panicBuzzed = false
            return
        }
        guard let start = panicHoldStart else {
            panicHoldStart = now
            return
        }
        // A buzz a second in, so a hand holding on feels that the stop is
        // coming and can let go.
        if !panicBuzzed, now - start >= 1 {
            panicBuzzed = true
            buzzEveryController(intensity: 0.5, ms: 150)
        }
        if now - start >= service.holdSeconds {
            panicHoldStart = nil
            panicBuzzed = false
            service.stop(reason: .controllerHold)
        }
    }

    private var panicBuzzed = false

    func buzzEveryController(intensity: Float, ms: Int) {
        for c in controllerService.connectedControllers {
            FeedbackService.shared.vibrate(controller: c, intensity: intensity, durationMs: ms)
        }
    }

    /// Whether the controller emergency hold is held on any pad right now:
    /// the button from Settings, with Start too when the default needs it,
    /// or Options alone on an Access Controller (its base profile sends
    /// neither Create nor Start).
    func emergencyHoldIsDown(useFrame: Bool = false) -> Bool {
        let service = EmergencyStopService.shared
        let button = service.controllerButton
        let needsStart = service.holdNeedsStart
        // Every slot with a controller in it, by the slot it sits in: a
        // group redirected to slot 1 left the pad in slot 0 unread, and a
        // count-based range missed a raw HID pad in a higher slot.
        var slots = Set(controllerService.controllerDetails.keys)
        slots.formUnion(controllerService.rawHIDGamepadSlots.keys)
        if let steam = controllerService.steamControllerSlot { slots.insert(steam) }
        for slot in slots.sorted() {
            // Prefer the state this frame already read.
            guard let state = (useFrame ? stateByReadSlot[slot] : nil) ?? controllerService.readControllerState(at: slot) else { continue }
            func down(_ standard: Int) -> Bool {
                // The Steam Controller numbers its buttons its own way: its
                // index 8 is D-pad up, so holding it stopped every preset.
                let index = slot == controllerService.steamControllerSlot
                    ? SteamControllerButton.index(forStandardButton: standard) : standard
                return index.map { (state.buttons[$0] ?? 0) > 0.5 } ?? false
            }
            if button == EmergencyStopService.defaultControllerButton, down(EmergencyStopService.startButton),
               ControllerLayoutResolver.cachedMatch(service: controllerService, slot: slot)?.id == .psAccess {
                return true
            }
            if down(button) && (!needsStart || down(EmergencyStopService.startButton)) { return true }
        }
        return false
    }

    // MARK: - Starting again after a controller stop

    private var restartWatch: Timer?
    private var restartHoldStart: TimeInterval?

    /// After the controller hold stopped everything, the same hold starts
    /// the last preset again, so someone who runs the Mac from a controller
    /// is not left with a dead controller and no way back. Watches for ten
    /// minutes, or until a preset starts another way.
    private var restartAction: (() -> Void)?
    private var restartUntil: CFTimeInterval = 0
    private var restartReleased = false

    func watchForRestartHold(_ restart: @escaping () -> Void) {
        restartWatch?.invalidate()
        restartHoldStart = nil
        restartAction = restart
        restartUntil = CACurrentMediaTime() + 600
        restartReleased = false
        restartWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartTick() }
        }
    }

    private func restartTick() {
        guard !isRunning, CACurrentMediaTime() < restartUntil,
              EmergencyStopService.shared.controllerHoldEnabled, let restart = restartAction else {
            restartWatch?.invalidate(); restartWatch = nil; restartAction = nil; return
        }
        let down = emergencyHoldIsDown()
        // The hold that stopped it has to be let go first.
        if !down { restartReleased = true; restartHoldStart = nil; return }
        guard restartReleased else { return }
        let now = CACurrentMediaTime()
        guard let start = restartHoldStart else { restartHoldStart = now; return }
        if now - start >= EmergencyStopService.shared.holdSeconds {
            restartWatch?.invalidate()
            restartWatch = nil
            restartAction = nil
            buzzEveryController(intensity: 0.6, ms: 120)
            restart()
        }
    }


    /// Returns cached serialized key for a binding's input to avoid string allocations in 120Hz loop
    private func cachedKey(for binding: BindingModel) -> String {
        if let cached = serializedKeyCache[binding.id] { return cached }
        let key = binding.input.serialized
        serializedKeyCache[binding.id] = key
        return key
    }

    /// Remap a raw axis magnitude (0...1) through the binding's inner and
    /// outer deadzones. Below the inner deadzone the result is 0. Above the
    /// outer deadzone the result is 1. Between them the value is linearly
    /// scaled so the full 0...1 output range is reached without having to
    /// push the stick to the absolute mechanical limit.
    private func remapMagnitude(_ magnitude: Float, binding: BindingModel?) -> Float {
        let inner = binding?.deadzone ?? defaultAxisThreshold
        let outer = binding?.outerDeadzone ?? 1.0
        let safeOuter = max(min(outer, 1.0), inner + 0.01)  // never collapse the range
        let m = max(0, min(1, magnitude))
        if m <= inner { return 0 }
        if m >= safeOuter { return 1 }
        return (m - inner) / (safeOuter - inner)
    }

    // MARK: - External Input Ingestion

    /// Routes one event from `ExternalInputDeviceService` into the parallel
    /// state maps. Called on main, so no locking is needed - the 120 Hz
    /// poll loop reads the same maps from the same actor.
    /// Latest Force Touch pressure (0-1) and click stage from the Mac
    /// trackpad, fed by pressureChanged events while external-input
    /// monitoring runs.
    private var externalPressure: Float = 0
    private var externalPressureStage: Int = 0
    /// A double click is a moment, not a state: the second click stamps a
    /// short window during which a Double click row reads as pressed.
    private var externalDoubleClickUntil: [String: Date] = [:]
    /// Devices with a finger scroll gesture in progress, momentum included.
    private var externalScrollGestureActive: Set<String> = []

    private func ingestExternalEvent(_ event: ExternalInputDeviceService.Event) {
        switch event {
        case .keyDown(let dev, let code):
            var s = externalKeysDown[dev] ?? []
            s.insert(code)
            externalKeysDown[dev] = s
        case .keyUp(let dev, let code):
            var s = externalKeysDown[dev] ?? []
            s.remove(code)
            externalKeysDown[dev] = s
        case .mouseButtonDown(let dev, let btn):
            var s = externalMouseButtonsDown[dev] ?? []
            s.insert(btn)
            externalMouseButtonsDown[dev] = s
        case .mouseButtonUp(let dev, let btn):
            var s = externalMouseButtonsDown[dev] ?? []
            s.remove(btn)
            externalMouseButtonsDown[dev] = s
        case .mouseMove(let dev, let dx, let dy):
            externalMouseDX[dev] = (externalMouseDX[dev] ?? 0) + dx
            externalMouseDY[dev] = (externalMouseDY[dev] ?? 0) + dy
        case .scroll(let dev, let dx, let dy):
            externalScrollDX[dev] = (externalScrollDX[dev] ?? 0) + dx
            externalScrollDY[dev] = (externalScrollDY[dev] ?? 0) + dy
        case .pressureChanged(_, let value, let stage):
            externalPressure = value
            externalPressureStage = stage
        case .mouseDoubleClick(let dev, let btn):
            externalDoubleClickUntil["\(dev)/\(btn)"] = Date().addingTimeInterval(0.2)
        case .scrollGesture(let dev, let active):
            if active { externalScrollGestureActive.insert(dev) } else { externalScrollGestureActive.remove(dev) }
        }
    }

    /// Evaluates an external `.extKey` or `.extMouse` input against the
    /// parallel state maps. `nil` device ID matches any device - useful
    /// for bindings the user wants to fire from "any keyboard".
    private func checkExternalInput(_ input: InputEvent) -> Bool {
        switch input.type {
        case .extKey:
            let hidCode = input.index
            if let dev = input.extDeviceID {
                return externalKeysDown[dev]?.contains(hidCode) ?? false
            }
            for (_, set) in externalKeysDown where set.contains(hidCode) {
                return true
            }
            return false
        case .extMouse:
            switch input.extMouseKind ?? .button {
            case .button:
                let btn = input.index
                if let dev = input.extDeviceID {
                    return externalMouseButtonsDown[dev]?.contains(btn) ?? false
                }
                for (_, set) in externalMouseButtonsDown where set.contains(btn) {
                    return true
                }
                return false
            case .pressure:
                // Analog Force Touch press as a threshold input. 0.25 sits
                // just under the force of a normal click, so a deliberate
                // light press fires without requiring the full click.
                return externalPressure >= 0.25
            case .deepPress:
                return externalPressureStage >= 2
            case .doubleClick:
                let now = Date()
                if let dev = input.extDeviceID {
                    return (externalDoubleClickUntil["\(dev)/\(input.index)"] ?? .distantPast) > now
                }
                return externalDoubleClickUntil.contains { $0.key.hasSuffix("/\(input.index)") && $0.value > now }
            case .scrollGesture:
                if let dev = input.extDeviceID { return externalScrollGestureActive.contains(dev) }
                return !externalScrollGestureActive.isEmpty
            case .moveX, .moveY, .scrollX, .scrollY:
                // Half-axis style: positive direction means delta > 0, etc.
                // Threshold is 1 because HID deltas come through as integer
                // ticks that can be very small per frame.
                let delta: Int
                switch input.extMouseKind {
                case .moveX:
                    delta = input.extDeviceID.flatMap { externalMouseDX[$0] }
                        ?? externalMouseDX.values.reduce(0, +)
                case .moveY:
                    delta = input.extDeviceID.flatMap { externalMouseDY[$0] }
                        ?? externalMouseDY.values.reduce(0, +)
                case .scrollX:
                    delta = input.extDeviceID.flatMap { externalScrollDX[$0] }
                        ?? externalScrollDX.values.reduce(0, +)
                case .scrollY:
                    delta = input.extDeviceID.flatMap { externalScrollDY[$0] }
                        ?? externalScrollDY.values.reduce(0, +)
                default:
                    delta = 0
                }
                switch input.axisDirection {
                case .positive: return delta > 0
                case .negative: return delta < 0
                case .none:     return delta != 0
                }
            }
        default:
            return false
        }
    }

    // MARK: - Input Checking

    private func checkInput(_ input: InputEvent, state: ControllerState, binding: BindingModel? = nil) -> Bool {
        let axisThreshold = binding?.deadzone ?? defaultAxisThreshold

        switch input.type {
        case .button:
            return (state.buttons[input.index] ?? 0) > 0.5

        case .axis:
            guard var value = state.axes[input.index] else { return false }
            if binding?.invertAxis == true { value = -value }
            // Release a little below the activation point, so sensor noise
            // at the edge is not a press and release every frame.
            let threshold = hysteresisActive ? axisThreshold * 0.9 : axisThreshold
            switch input.axisDirection {
            case .positive:
                return value > threshold
            case .negative:
                return value < -threshold
            case .none:
                return abs(value) > threshold
            }

        case .hat:
            guard let hat = state.hats[input.index] else { return false }
            // Inclusive (>=) comparisons so an exact-edge value of 0.5
            // counts as pressed. Many d-pads quantize to {-1, 0, +1};
            // the > variant was correct for those but missed analog
            // d-pads that report exactly the threshold value on a
            // slow-press transition.
            switch input.hatDirection {
            case .up:
                return hat.y >= hatThreshold
            case .down:
                return hat.y <= -hatThreshold
            case .left:
                return hat.x <= -hatThreshold
            case .right:
                return hat.x >= hatThreshold
            case .none:
                return false
            }

        case .touchpad:
            // A touchpad "axis" is considered active while the finger is in
            // contact AND there is non-trivial motion in the requested
            // direction since the last poll. Motion driven outputs read the
            // delta directly via processAxisInput.
            let finger = input.touchpadFinger ?? input.index
            let pad = touchService(input.touchpadSurface)
            guard pad.isFingerActive(finger),
                  let axis = input.touchpadAxis else { return false }
            // Peek without consuming so the continuous-output pass
            // later in the same poll frame still sees the delta. The
            // old code called consumeDelta here, zeroing the
            // accumulator, which broke analog touchpad-to-mouse
            // bindings (they fired once on swipe entry, then nothing).
            let value = pad.peekDelta(finger: finger, axis: axis)
            // This is a per-frame delta as a fraction of the pad, not a
            // stick position, so a stick deadzone is the wrong yardstick by
            // three orders of magnitude: against the default 0.25 a finger
            // would have to cross a quarter of the pad inside one 8 ms poll
            // to count, so no swipe ever activated the row and nothing was
            // output. Anything past a pixel or so of real movement counts.
            let moved = Self.touchpadMotionThreshold
            switch input.axisDirection {
            case .positive: return value > moved
            case .negative: return value < -moved
            case .none:     return abs(value) > moved
            }

        case .touchpadRegion:
            // Press for as long as any finger sits inside the named region.
            guard let id = input.touchpadRegionID else { return false }
            return touchService(nil).isRegionPressed(id)

        case .cursorRegion:
            // Mac-trackpad / mouse analog of `.touchpadRegion`: press
            // while the cursor sits inside a user-defined screen rect.
            // Position is fed continuously by ExternalInputDeviceService's
            // CGEventTap as the cursor moves.
            guard let id = input.cursorRegionID else { return false }
            return CursorRegionService.shared.isRegionPressed(id)

        case .stickRegion:
            // Joystick stick analog of `.touchpadRegion`: press
            // while the stick at input.index (0 = left, 1 = right)
            // is deflected into the named region. We respect the
            // binding's deadzone (so resting drift can't fire a
            // center region) and invertAxis (so a flipped-stick
            // binding sees the region in the same logical orientation
            // the user drew it).
            guard let id = input.stickRegionID else { return false }
            // Pull the two axes for the requested stick.
            let xAxisIdx = input.index == 1 ? 2 : 0
            let yAxisIdx = input.index == 1 ? 3 : 1
            var xRaw = state.axes[xAxisIdx] ?? 0
            var yRaw = state.axes[yAxisIdx] ?? 0
            // Deadzone gate: if the stick magnitude is below the
            // threshold, no region fires - prevents drift-driven
            // false positives.
            if hypot(xRaw, yRaw) < axisThreshold { return false }
            if binding?.invertAxis == true {
                xRaw = -xRaw
                yRaw = -yRaw
            }
            // Pass the corrected values directly. Re-packing them into a
            // cloned axes dict copied the slot's whole dictionary every
            // deflected frame just to override these two entries.
            return StickRegionService.shared.isRegionPressed(id, x: xRaw, y: yRaw)

        case .touchpadGesture:
            // Touchpad gestures (two-finger tap, etc.) are edge-fire:
            // TouchpadService sets a one-shot flag when it detects the
            // gesture; consumeGesture returns true exactly once and
            // resets. The MappingEngine treats that single-frame pulse
            // as a press + release, which fires whatever output the
            // user bound. Multiple bindings on the same gesture all
            // see the flag inside this poll frame because consume only
            // resets once they've all read true once - no, wait:
            // consume clears immediately. If two bindings reference
            // the same gesture, only one fires. That's intended:
            // stack bindings live in the SAME row's outputs[], not
            // separate rows.
            guard let kind = input.touchpadGestureKind else { return false }
            return touchService(input.touchpadSurface).consumeGesture(kind)

        case .motion:
            // Motion is treated as a half-axis: pick the channel and
            // direction the binding asked for, threshold on a small dead
            // zone so resting drift doesn't fire the binding.
            guard let channel = input.motionChannel,
                  let raw = state.motion[channel] else { return false }
            if currentSlotMotionMuted { return false }
            // A row that presses keys, buttons, or MIDI is a half-axis switch:
            // its own direction, past its deadzone. The either-way firing
            // below is for pointer rows, which zero the half they do not own;
            // for a key it meant "Gyro Y +" pressed on any tilt, even tremor.
            if let binding, !Self.drivesPointer(binding) {
                return Self.motionFires(value: raw, direction: input.axisDirection,
                                        invert: binding.invertAxis ?? false,
                                        deadzone: binding.deadzone ?? Float(Self.motionSwitchDeadzone))
            }
            // Both half-axis rows fire whenever there is anything to move;
            // each zeroes the half it does not own when it computes its delta.
            if let pending = pendingTilt(group: pollingJoystickIndex, channel: channel, state: state,
                                         deadzone: binding?.deadzone) {
                // Pointing: fire while the pointer still has offset to cover.
                // 0.0003 rad is under a third of a pixel at Speed 6.
                return abs(pending) > 0.0003
            }
            let correction = state.motionCorrection[channel] ?? 0
            return abs(raw) >= 0.005 || abs(correction) > 0.00001

        case .extKey, .extMouse:
            // Routed through `checkExternalInput` instead; this branch is
            // only reachable from legacy code paths that don't expect
            // external types.
            return checkExternalInput(input)

        case .chassisTap:
            // Edge-fire, exactly like a touchpad gesture: the service raises a
            // one-shot flag when a tap group closes and holds it briefly so
            // the poll loop sees a press and then a release.
            return ChassisTapService.shared.consumeTap(count: input.index)

        case .midi:
            return checkMIDIInput(input, binding: binding, threshold: axisThreshold)
        }
    }

    /// Deadzone for a motion row that works as a switch, when the row sets
    /// none: gyro rad/s or accelerometer g, the same default the row's
    /// Motion panel shows.
    nonisolated static let motionSwitchDeadzone: Double = 0.25

    /// Whether a motion reading fires a switch-style row. Shared with the
    /// row's Motion panel so the green light matches what the engine does.
    nonisolated static func motionFires(value: Float, direction: AxisDirection?, invert: Bool, deadzone: Float) -> Bool {
        let v = invert ? -value : value
        switch direction {
        case .positive: return v > deadzone
        case .negative: return v < -deadzone
        default:        return abs(v) > deadzone
        }
    }

    /// A Mac keyboard modifier row (left Command) that also sends that same
    /// modifier as an output (Command Tab) can never see the key let go:
    /// while the app holds the key, the key reads down. The output dropped
    /// it, and the person's own finger already holds it, so Command Tab
    /// still works and the key is released when they let go.
    nonisolated static func withoutSelfModifierOutputs(_ groups: [JoystickMapping]) -> [JoystickMapping] {
        selfModifierRows(groups).groups
    }

    /// The groups with those outputs dropped, and for each such row the
    /// modifier it dropped. Its other keys still carry that modifier while
    /// the person holds it (see InputSimulator.scopedModifierFlags): a
    /// posted key writes all of its flags, so without it Command Tab went
    /// out as a plain Tab.
    nonisolated static func selfModifierRows(_ groups: [JoystickMapping]) -> (groups: [JoystickMapping], dropped: [UUID: Int]) {
        var groups = groups
        var dropped: [UUID: Int] = [:]
        for g in groups.indices {
            for r in groups[g].bindings.indices {
                let input = groups[g].bindings[r].input
                guard input.type == .extKey, (224...231).contains(input.index) else { continue }
                let row = groups[g].bindings[r]
                // Only what fires while the key is physically down: on a tap
                // or double tap row the tap and double-tap actions go out
                // after the key is let go, when there is no finger to supply
                // the modifier, so they keep it (Shift Command 4 on a double
                // tap became Command 4). The engine never reads a key it holds
                // itself, so a pulse after release cannot latch the input.
                let deferred = row.macroSteps == nil && (row.holdOutputs != nil || row.doubleTapOutputs != nil)
                let heldLists = deferred ? [row.holdOutputs].compactMap { $0 }
                                         : [row.outputs] + [row.holdOutputs].compactMap { $0 }
                if heldLists.contains(where: { $0.contains { $0.type == .key && $0.keyCode == input.index } }) {
                    dropped[row.id] = input.index
                }
                func strip(_ list: [OutputAction]) -> [OutputAction] {
                    list.filter { !($0.type == .key && $0.keyCode == input.index) }
                }
                if !deferred { groups[g].bindings[r].outputs = strip(groups[g].bindings[r].outputs) }
                groups[g].bindings[r].holdOutputs = groups[g].bindings[r].holdOutputs.map(strip)
            }
        }
        return (groups, dropped)
    }

    /// Rows that move the pointer from their input. Not scroll: the scroll
    /// path has no motion branch, so a tilt-to-scroll row counted as a
    /// pointer row fired whichever way the pad turned, at full speed, and a
    /// tilt-forward and tilt-back pair canceled out. A motion row that
    /// scrolls is a direction switch past its deadzone, like a key row.
    nonisolated static func drivesPointer(_ binding: BindingModel) -> Bool {
        binding.outputs.contains { $0.type == .mouseMotion }
    }

    /// Evaluates a `.midi` input against MIDIInputService's live state.
    /// Notes and program changes behave like buttons; CC, pitch bend, and
    /// aftertouch are continuous, so they threshold like an axis and can
    /// also drive analog outputs through `midiAxisValue`.
    private func checkMIDIInput(_ input: InputEvent,
                                binding: BindingModel?,
                                threshold: Float) -> Bool {
        let service = MIDIInputService.shared
        let channel = input.midiChannel
        let device = input.midiDeviceID

        switch input.midiKind ?? .note {
        case .note:
            return service.isNoteDown(input.index, channel: channel, deviceID: device)

        case .programChange:
            // Momentary: true for exactly one poll frame after arrival.
            return service.consumeProgramChange(input.index, channel: channel, deviceID: device)

        case .transport:
            // Momentary like Program Change; transport has no channel.
            return service.consumeTransport(UInt8(clamping: input.index), deviceID: device)

        case .cc:
            switch input.midiCCMode ?? .threshold {
            case .threshold:
                // A knob at rest reads its last value, so a plain "CC moved"
                // binding uses the halfway point as the press threshold -
                // that matches how a sustain pedal or a switch-style CC
                // (0 = off, 127 = on) behaves, which is the common case.
                guard let value = service.ccValue(input.index, channel: channel, deviceID: device) else {
                    return false
                }
                let normalized = Float(value) / 127.0
                switch input.axisDirection {
                case .negative: return normalized < 0.5
                default:        return normalized >= 0.5
                }

            case .centered:
                // Dial mode: center (64) is zero and the binding behaves
                // like a stick axis, so the same deadzone that gates a
                // stick gates the dial. The + direction is the right half
                // of the knob, - the left half.
                guard let raw = service.ccValue(input.index, channel: channel, deviceID: device) else {
                    return false
                }
                var v = max(-1, min(1, Float(raw - 64) / 63.5))
                if binding?.invertAxis == true { v = -v }
                switch input.axisDirection {
                case .positive: return v > threshold
                case .negative: return v < -threshold
                case .none:     return abs(v) > threshold
                }

            case .relative:
                // Turn mode: every few raw units of travel in the bound
                // direction is one step, delivered as a press frame
                // followed by a forced release frame so consecutive
                // steps arrive as distinct key presses.
                let up = (input.axisDirection ?? .positive) != .negative
                let key = (binding?.id.uuidString ?? "scan") + (up ? "+" : "-")
                let step = max(1, min(32, input.midiTurnStep ?? 4))
                return service.consumeRelativeStep(cc: input.index, channel: channel,
                                                   deviceID: device, up: up,
                                                   consumerKey: key, stepUnits: step)
            }

        case .pitchBend:
            let value = service.pitchBendValue(channel: channel, deviceID: device)
            let v = (binding?.invertAxis == true) ? -value : value
            switch input.axisDirection {
            case .positive: return v > threshold
            case .negative: return v < -threshold
            case .none:     return abs(v) > threshold
            }

        case .aftertouch:
            let value = Float(service.aftertouchValue(channel: channel, deviceID: device)) / 127.0
            return value > threshold
        }
    }

    /// Absolute 0...1 position of a continuous input, for outputs that
    /// FOLLOW the control rather than react to it (system volume). A CC
    /// knob reports its raw position regardless of knob mode; the pitch
    /// wheel and full-range axes map -1...1 onto 0...1; triggers and
    /// aftertouch are naturally 0...1 already.
    private func absolutePosition(for input: InputEvent, state: ControllerState) -> Float? {
        switch input.type {
        case .midi:
            let service = MIDIInputService.shared
            switch input.midiKind ?? .note {
            case .cc:
                guard let v = service.ccValue(input.index, channel: input.midiChannel,
                                              deviceID: input.midiDeviceID) else { return nil }
                return Float(v) / 127.0
            case .pitchBend:
                let v = service.pitchBendValue(channel: input.midiChannel,
                                               deviceID: input.midiDeviceID)
                return (v + 1) / 2
            case .aftertouch:
                return Float(service.aftertouchValue(channel: input.midiChannel,
                                                     deviceID: input.midiDeviceID)) / 127.0
            case .note, .programChange, .transport:
                return nil
            }
        case .axis:
            guard var v = state.axes[input.index] else { return nil }
            switch input.axisDirection {
            case .positive: return max(0, min(1, v))
            case .negative: return max(0, min(1, -v))
            case .none:
                v = max(-1, min(1, v))
                return (v + 1) / 2
            }
        default:
            return nil
        }
    }

    /// Continuous value for a `.midi` input, normalized to the same
    /// -1...1 range the axis outputs (mouse motion, scroll) expect.
    /// Returns nil for message families that aren't continuous.
    func midiAxisValue(_ input: InputEvent) -> Float? {
        let service = MIDIInputService.shared
        let channel = input.midiChannel
        let device = input.midiDeviceID
        switch input.midiKind ?? .note {
        case .cc:
            guard let v = service.ccValue(input.index, channel: channel, deviceID: device) else { return nil }
            switch input.midiCCMode ?? .threshold {
            case .centered:
                // Signed dial position, -1 at full left through +1 at
                // full right, center = 0.
                return max(-1, min(1, Float(v - 64) / 63.5))
            case .threshold:
                return Float(v) / 127.0
            case .relative:
                // Turn mode has no standing position; it is consumed as
                // discrete steps in checkMIDIInput.
                return nil
            }
        case .pitchBend:
            return service.pitchBendValue(channel: channel, deviceID: device)
        case .aftertouch:
            return Float(service.aftertouchValue(channel: channel, deviceID: device)) / 127.0
        case .note, .programChange, .transport:
            return nil
        }
    }

    // MARK: - Output Firing

    /// One poll step of a turbo run: fires when the gap has elapsed, with the
    /// row's interval (ms takes precedence over the older presses-per-second),
    /// an optional random +/- on every gap, and an optional press limit.
    /// Returns false once the limit is reached so a toggled run can stop.
    /// Each turbo row's next gap, drawn when it last fired.
    private var turboNextInterval: [String: Double] = [:]

    /// True while turboTick fires a pulse, so its clicks go out as single
    /// clicks rather than chaining into double and triple clicks.
    private var firingTurboPulse = false

    /// Each row's turbo pulse that is down and not yet let go.
    private var turboPulseDown: [String: (pulse: Int, outputs: [OutputAction], axis: Bool)] = [:]
    private var turboPulseCounter = 0

    private func turboTick(_ binding: BindingModel, bindKey: String, inputIsAxis: Bool, now: CFTimeInterval) -> Bool {
        let maxCount = binding.turboMaxCount ?? 0
        let fired = turboCounts[bindKey] ?? 0
        if maxCount > 0, fired >= maxCount { return false }
        let base: Double
        if let ms = binding.turboIntervalMs, ms > 0 {
            base = Double(max(5, min(60_000, ms))) / 1000
        } else {
            // Clamp the rate so a zero or negative value from a malformed
            // preset cannot produce an infinite interval. 1 Hz to 60 Hz.
            base = 1.0 / Double(max(1, min(60, binding.turboRate ?? 10)))
        }
        // The gap to wait, drawn once per fire. Drawing a fresh random gap
        // on every 120 Hz poll made the wait the shortest of many draws, so
        // "vary by N ms" sped clicking up instead of spreading it evenly.
        let releaseDelay = min(0.08, base * 0.4)
        let interval = turboNextInterval[bindKey] ?? base
        let lastFire = turboTimestamps[bindKey] ?? -.infinity
        guard now - lastFire >= interval else { return true }
        var next = base
        if let jitter = binding.turboJitterMs, jitter > 0 {
            next = base + Double.random(in: -Double(jitter)...Double(jitter)) / 1000
        }
        // Never before the previous press has been let go, or two presses
        // run together into one. 2 ms of air is enough; the 10 ms this used
        // to add held a 5 to 10 ms turbo to every second frame.
        turboNextInterval[bindKey] = max(releaseDelay + 0.002, next)
        // The previous pulse not let go yet (the main thread stalled past
        // the gap): let go now, or this press found the key still down,
        // went nowhere, and was counted anyway, so Stop after N sent fewer.
        if let pending = turboPulseDown[bindKey] {
            turboPulseDown[bindKey] = nil
            fireOutputs(pending.outputs, press: false, inputIsAxis: pending.axis, owner: bindKey)
        }
        firingTurboPulse = true
        fireOutputs(binding.outputs, press: true, inputIsAxis: inputIsAxis, owner: bindKey)
        firingTurboPulse = false
        turboCounts[bindKey] = fired + 1
        // Release after ~40% of the gap (capped so slow auto-clicks still
        // feel like clicks). engineGeneration guards a stop() in between.
        let gen = engineGeneration
        // On a stick or trigger, a CC or pitch bend follows the stick on the
        // continuous path; a pulse release sent its rest value (CC 0, bend
        // center) ten times a second, so the value flickered. The rest value
        // goes out once, when the row really lets go (TURBO END).
        let outputs = inputIsAxis
            ? binding.outputs.filter { $0.type != .midiCC && $0.type != .midiPitchBend }
            : binding.outputs
        let axisFlag = inputIsAxis
        turboPulseCounter &+= 1
        let pulse = turboPulseCounter
        turboPulseDown[bindKey] = (pulse, outputs, axisFlag)
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) { [weak self] in
            guard let self = self, self.engineGeneration == gen,
                  self.turboPulseDown[bindKey]?.pulse == pulse else { return }
            self.turboPulseDown[bindKey] = nil
            self.fireOutputs(outputs, press: false, inputIsAxis: axisFlag, owner: bindKey)
        }
        // Due times advance by the gap rather than snapping to the poll
        // frame, so the rate averages what the editor shows (a 10 ms gap at
        // 120 Hz ran at 60 a second). Never more than one gap behind.
        turboTimestamps[bindKey] = lastFire.isFinite ? max(lastFire + interval, now - interval) : now
        return !(maxCount > 0 && fired + 1 >= maxCount)
    }

    /// "D-pad: one direction at a time". The direction that went down first
    /// keeps the pad while it is held; a diagonal reached from rest counts as
    /// nothing until it settles on one side, so a graze never fires the
    /// neighboring row.
    private func oneDirectionHats(_ hats: [Int: (x: Float, y: Float)], group: Int) -> [Int: (x: Float, y: Float)] {
        Self.oneDirectionHats(hats, group: group, held: &dpadHeldAxis, threshold: hatThreshold)
    }

    /// The same, with the memory of which axis went down first passed in
    /// (1 across, 2 up and down, keyed by group times 16 plus the hat), so
    /// it can be checked on its own.
    nonisolated static func oneDirectionHats(_ hats: [Int: (x: Float, y: Float)], group: Int,
                                 held: inout [Int: UInt8], threshold: Float) -> [Int: (x: Float, y: Float)] {
        var out = hats
        for (index, hat) in hats {
            let key = group &* 16 &+ index
            let across = abs(hat.x) >= threshold
            let upDown = abs(hat.y) >= threshold
            switch (across, upDown) {
            case (false, false): held[key] = nil
            case (true, false): held[key] = 1
            case (false, true): held[key] = 2
            case (true, true):
                switch held[key] {
                case 1: out[index] = (x: hat.x, y: 0)
                case 2: out[index] = (x: 0, y: hat.y)
                default: out[index] = (x: 0, y: 0)
                }
            }
        }
        return out
    }

    /// Slow the poll after a quiet spell, and bring it back the moment a
    /// row is active again. See `idlePolling`.
    private func updateIdlePolling(now: CFTimeInterval) {
        // pointerOnly, not pointerWhileEditing: with the editor open at the
        // lock screen the pointer still passes, and idling never ran there.
        guard idleEligible, !outputsPaused || pointerOnly else { return }
        let busy = activeStates.values.contains { !$0.isEmpty }
            || toggleStates.values.contains(true)
            || !macrosInFlight.isEmpty || !deferredPressStart.isEmpty || !holdFired.isEmpty
            // Raw HID and Steam pads do not report activity the way
            // GameController pads do, so nothing would wake the slow poll
            // for them and a quick tap between two slow ticks was lost.
            // Only the ones this preset reads: a Stream Deck or adapter left
            // plugged in kept every preset at the full rate.
            || readsDirectPad
        if busy { lastInputChangeAt = now }
        if idlePolling {
            if busy {
                idlePolling = false
                installPollTimer()
            }
        } else if now - lastInputChangeAt > Self.idleAfter {
            idlePolling = true
            installPollTimer()
        }
    }

    /// GameController reported a change on a controller. This runs on every
    /// stick and button report, so it only stamps the time, and swaps the
    /// timer back to full rate (with a poll right away) when it was resting.
    private func noteInputActivity() {
        lastInputChangeAt = CACurrentMediaTime()
        guard idlePolling, isRunning, !outputsPaused || pointerOnly else { return }
        idlePolling = false
        installPollTimer()
        pollControllers()
    }

    /// Control, Shift, Option, Command (left and right) and Globe.
    private static func isModifierKeyCode(_ code: Int) -> Bool {
        (224...231).contains(code) || code == KeyCodeMap.globeFnCode
    }

    /// `owner` names who holds the keys and buttons this press puts down
    /// (a row's bindKey, its hold action, its macro). A key another row
    /// still holds stays down when this owner lets go; see InputSimulator.
    private func fireOutputs(_ outputs: [OutputAction], press: Bool, inputIsAxis: Bool = false,
                             owner: String = "", repeats: Bool = false, restingCCValue: Int? = nil) {
        // App actions run even while outputs are paused; otherwise a
        // controller-bound Pause / Resume binding could pause the engine and
        // never resume it. Hopped to main async because activating a preset
        // restarts the engine, which must not happen mid-poll.
        if press {
            for output in outputs where output.type == .appAction {
                let kind = output.appActionKind ?? .togglePauseOutputs
                // Held-only gate, handled per frame in pollControllers.
                if kind == .holdMuteMotion { continue }
                // At the lock screen or asleep only the actions that stop
                // things run; switching presets or re-zeroing waits.
                if !suspendReasons.isEmpty,
                   ![.togglePauseOutputs, .deactivate, .emergencyStop].contains(kind) { continue }
                let target = output.targetPresetID
                // The controller slot this group is reading, not the group
                // number: re-zero must hit the controller that was pressed.
                // A press fired later (a single tap resolved after the
                // double-tap window, a repeat step) runs after the loop, so
                // the group comes from the owner ("2:..."), not from the
                // group polled last.
                let group = owner.split(separator: ":", maxSplits: 1).first.flatMap { Int($0) } ?? pollingJoystickIndex
                let source = slotForGroup[group] ?? group
                DispatchQueue.main.async {
                    MenuBarController.shared.performAppAction(kind, targetPresetID: target, sourceJoystick: source)
                }
            }
        }
        var outputs = outputs
        if outputsBlocked {
            guard pointerOnly, !touchpadHeldBack(owner: owner) else { return }
            outputs = passingOutputs(outputs)
            if outputs.isEmpty { return }
        }
        if press {
            for output in outputs {
                switch output.type {
                case .key: StatsService.shared.recordKeyPress()
                case .mouseButton: StatsService.shared.recordMouseClick()
                case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport:
                    StatsService.shared.recordMidiEvent()
                default: break
                }
            }
        }
        // Every key of this row, so each key carries only its own row's
        // modifiers (plus any held on their own); see InputSimulator.keyDown.
        var chordKeys = outputs.compactMap { $0.type == .key ? $0.keyCode : nil }
        // A row on a Mac modifier that also sent that modifier: its keys
        // carry the modifier the person is holding.
        if !chordKeys.isEmpty, !selfModifierByRow.isEmpty,
           let idText = owner.split(separator: ":", maxSplits: 1).dropFirst().first.map({ String($0.prefix(36)) }),
           let rowID = UUID(uuidString: idText), let mod = selfModifierByRow[rowID] {
            chordKeys.append(mod)
        }
        // On a press the keys go first, modifiers ahead of the key they
        // modify; on a release the keys go last, the key ahead of its
        // modifiers. That is the order a hand uses: Command goes down before
        // C and comes up after it, and an Option drag lets go of the mouse
        // before Option, so a copy does not turn into a move at the end.
        let ordered: [OutputAction]
        if chordKeys.isEmpty {
            ordered = outputs
        } else {
            let mods = outputs.filter { $0.type == .key && ($0.keyCode.map(Self.isModifierKeyCode) ?? false) }
            let keys = outputs.filter { $0.type == .key && !($0.keyCode.map(Self.isModifierKeyCode) ?? false) }
            let rest = outputs.filter { $0.type != .key }
            ordered = press ? mods + keys + rest : rest + keys + mods
        }
        for output in ordered {
            switch output.type {
            case .key:
                if let code = output.keyCode {
                    if press {
                        InputSimulator.shared.keyDown(code, chord: chordKeys, owner: owner, repeats: repeats)
                    } else {
                        InputSimulator.shared.keyUp(code, owner: owner)
                    }
                }

            case .mouseButton:
                do {
                    let btn = output.resolvedMouseButton
                    if press {
                        if let x = output.clickX, let y = output.clickY {
                            // The point was captured on a display that may be
                            // gone (a laptop off its monitor); clicking there
                            // would land wherever the pointer is. Skip it.
                            var count: UInt32 = 0
                            CGGetDisplaysWithPoint(CGPoint(x: x, y: y), 0, nil, &count)
                            guard count > 0 else {
                                activity("Fixed click point (\(Int(x)), \(Int(y))) is off every screen; click skipped")
                                continue
                            }
                            InputSimulator.shared.placePointer(atX: x, y: y)
                        }
                        InputSimulator.shared.mouseButtonDown(btn, owner: owner, singleClick: firingTurboPulse)
                    } else {
                        InputSimulator.shared.mouseButtonUp(btn, owner: owner)
                    }
                }

            case .mouseWheelStep:
                if press {
                    InputSimulator.shared.scrollWheelStep(axis: output.resolvedMouseAxis,
                                                          direction: output.resolvedMouseDirection,
                                                          lines: Int(scrollGainCache.rounded()))
                }

            case .typeText:
                // Fire on press only; there is nothing to release.
                if press, let text = output.text, !text.isEmpty {
                    InputSimulator.shared.typeString(text)
                }

            case .appAction:
                // Dispatched above, before the pause gate.
                break

            case .absoluteVolume:
                // Follows the input continuously via fireContinuousOutputs;
                // a press edge has no meaning for a fader.
                break

            case .systemAction:
                // Fire on press only - a system function has no release
                // half. Hold + turbo and Turn-mode knobs repeat naturally
                // because each pulse is a fresh press edge.
                if press, let kind = output.systemActionKind {
                    SystemActionService.shared.perform(kind, parameter: output.text)
                }

            case .mouseMotion, .mouseWheel:
                break

            case .lightBar:
                fireLightOutput(output, press: press, owner: owner)

            case .midiNote:
                let note = output.midiNote ?? 60
                let vel = output.midiVelocity ?? 100
                let ch = output.midiChannel ?? 1
                if press {
                    MIDIService.shared.sendNoteOn(note: note, velocity: vel, channel: ch)
                } else {
                    MIDIService.shared.sendNoteOff(note: note, channel: ch)
                }

            case .midiCC:
                // Axis-driven CC is continuous: fireContinuousOutputs sends the
                // smoothly-scaled value every active frame. Firing on the edge
                // for an axis would spike the CC to the fixed value (127) for
                // one frame on every deadzone entry and slam it to 0 on
                // release, the same reason .mouseMotion/.mouseWheel break above.
                // Buttons still fire the configured value on press, 0 on release.
                // An axis row's release does send its rest value, or the CC
                // stayed wherever the stick was when it crossed back into the
                // deadzone: the continuous path stops at that edge.
                if inputIsAxis {
                    if !press {
                        MIDIService.shared.sendCC(controller: output.midiCCNumber ?? 1,
                                                  value: restingCCValue ?? 0,
                                                  channel: output.midiChannel ?? 1)
                    }
                    break
                }
                let cc = output.midiCCNumber ?? 1
                let ch = output.midiChannel ?? 1
                let value = press ? (output.midiCCValue ?? 127) : 0
                MIDIService.shared.sendCC(controller: cc, value: value, channel: ch)

            case .midiPitchBend:
                // Same as .midiCC: axes ride the continuous path; only buttons
                // snap to full bend on press and recenter on release. An axis
                // row recenters on release too (see .midiCC).
                if inputIsAxis {
                    if !press { MIDIService.shared.sendPitchBend(value: 8192, channel: output.midiChannel ?? 1) }
                    break
                }
                let ch = output.midiChannel ?? 1
                let value = press ? 16383 : 8192
                MIDIService.shared.sendPitchBend(value: value, channel: ch)

            case .midiProgramChange:
                // Program Change fires only on press. There's no "release"
                // for a program change - the instrument stays on the new
                // patch until something else changes it.
                if press {
                    let prog = output.midiProgramNumber ?? 0
                    let ch = output.midiChannel ?? 1
                    MIDIService.shared.sendProgramChange(program: prog, channel: ch)
                }

            case .midiTransport:
                // Transport messages fire on press only. Stop is symmetric
                // with Start in user terms - assign both to different buttons.
                if press {
                    MIDIService.shared.sendTransport(output.midiTransport ?? .start)
                }
            }
        }
    }

    // MARK: - Light bar outputs

    /// "While held" light colors that are showing, in press order, with the
    /// slots each one colored. The newest one on a slot is what it shows;
    /// letting it go shows the one under it, or puts the light back.
    private var heldLights: [(owner: String, slots: [Int], color: RGBLightColor)] = []

    /// The slots a row's light output colors: the controller its group
    /// reads, when that one has a light bar. A group that reads the Mac's
    /// keyboard, mouse, screen or MIDI has no controller of its own, so it
    /// colors every light bar.
    private func lightSlots(forOwner owner: String) -> [Int] {
        let group = owner.split(separator: ":", maxSplits: 1).first.flatMap { Int($0) } ?? pollingJoystickIndex
        let lit = controllerService.lightBarSlots()
        if let preset = activePreset, preset.joysticks.indices.contains(group),
           preset.joysticks[group].macInputName != nil {
            return lit
        }
        let slot = slotForGroup[group] ?? group
        return lit.contains(slot) ? [slot] : []
    }

    private func fireLightOutput(_ output: OutputAction, press: Bool, owner: String) {
        // A press that lets itself go a moment later (a double tap's
        // pulse) would only flash a held color, so it keeps it instead.
        var mode = output.resolvedLightMode
        if mode == .whileHeld, owner.contains("#pulse-") { mode = .set }
        guard press else {
            if mode == .whileHeld { releaseHeldLight(owner: owner) }
            return
        }
        let slots = lightSlots(forOwner: owner)
        guard !slots.isEmpty else {
            activity("Light bar color skipped: no DualSense or DualShock 4 on this row's controller",
                     key: "light-none")
            return
        }
        let color = output.resolvedLightColor
        switch mode {
        case .whileHeld:
            heldLights.removeAll { $0.owner == owner }
            heldLights.append((owner, slots, color))
            for slot in slots { controllerService.showOutputLight(slot: slot, color: color) }
        case .set:
            // The newest color wins on the light; a held one still down
            // gives way to it and comes back to this color when let go.
            for slot in slots { controllerService.setOutputLight(slot: slot, color: color) }
        case .rainbowToggle:
            for slot in slots { controllerService.toggleOutputRainbow(slot: slot) }
        }
    }

    /// Let go of one row's held light color.
    private func releaseHeldLight(owner: String) {
        guard let i = heldLights.firstIndex(where: { $0.owner == owner }) else { return }
        let entry = heldLights.remove(at: i)
        for slot in entry.slots {
            if let under = heldLights.last(where: { $0.slots.contains(slot) }) {
                controllerService.showOutputLight(slot: slot, color: under.color)
            } else {
                controllerService.restoreOutputLight(slot: slot)
            }
        }
    }

    /// Let go of every held light color, or only those of the rows whose
    /// owner starts with `prefix` (one group's, on a disconnect).
    private func releaseHeldLights(withPrefix prefix: String? = nil) {
        let owners = heldLights.map(\.owner).filter { prefix == nil || $0.hasPrefix(prefix!) }
        for owner in owners { releaseHeldLight(owner: owner) }
    }

    /// Execute a macro sequence asynchronously.
    ///
    /// Captures `engineGeneration` at schedule time. Each fireOutputs
    /// hop to main re-checks the captured value and bails immediately
    /// when they differ - i.e. the engine was stopped or restarted
    /// mid-macro. Without this guard a long macro (30 steps × 200 ms)
    /// keeps firing keyDown / keyUp events for minutes after the user
    /// deactivates the preset, leaving stuck synthesized keys.
    ///
    /// Step delays and holds are clamped to 30 s each so a malformed
    /// or adversarial preset with delayMs / holdMs = Int.max can't
    /// park a background thread for billions of years.
    // MARK: - Tap-vs-hold / double-tap state

    /// Monotonic press time per deferred binding (one with holdOutputs or
    /// doubleTapOutputs), recorded on the press transition; the decision of
    /// WHICH action fires is deferred until the hold threshold or release.
    private var deferredPressStart: [String: TimeInterval] = [:]
    /// Deferred bindings whose hold action is currently pressed.
    private var holdFired: Set<String> = []
    /// For a Mac modifier key row with a hold or double tap: the system's
    /// key-down count when the modifier went down. If it has moved by the
    /// hold threshold or the release, another key was pressed with it, so
    /// the modifier was part of a shortcut (Shift for a capital, Command C)
    /// and neither its hold nor its tap fires. Holding Right Shift through
    /// a word of capitals opened Mission Control.
    private var modifierKeyDownMark: [String: UInt32] = [:]

    /// Mac keyboard modifier keys (HID 224 to 231: Control, Shift, Option,
    /// Command, left and right). They send no key-down of their own, so
    /// the count only moves when some other key is pressed.
    private static func isModifierKeyInput(_ input: InputEvent) -> Bool {
        input.type == .extKey && (224...231).contains(input.index)
    }

    private static func keyDownEventCount() -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }

    private func otherKeyPressedDuringModifier(_ bindKey: String) -> Bool {
        guard let mark = modifierKeyDownMark[bindKey] else { return false }
        return Self.keyDownEventCount() != mark
    }
    /// Last tap-release time per double-tap binding, for window matching.
    private var lastTapTime: [String: TimeInterval] = [:]
    /// Incrementing token per binding that invalidates a scheduled
    /// single-tap fire when a second tap lands inside the window.
    private var pendingSingleTapToken: [String: Int] = [:]

    /// Resolve a tap-vs-hold / double-tap binding when its input releases.
    private func handleDeferredRelease(_ binding: BindingModel, bindKey: String, now: TimeInterval) {
        // No press on record: it was cleared by a pause, a lock or a sleep
        // while the control was held. The hold it started was let go then;
        // this release is not a tap.
        guard deferredPressStart.removeValue(forKey: bindKey) != nil else {
            modifierKeyDownMark.removeValue(forKey: bindKey)
            holdFired.remove(bindKey)
            secondTapPressed.remove(bindKey)
            return
        }
        let usedInShortcut = otherKeyPressedDuringModifier(bindKey)
        modifierKeyDownMark.removeValue(forKey: bindKey)
        if holdFired.contains(bindKey) {
            // The hold action is down; release it.
            holdFired.remove(bindKey)
            secondTapPressed.remove(bindKey)
            fireOutputs(binding.holdOutputs ?? [], press: false, owner: bindKey + "#hold")
            return
        }
        // A modifier that took part in a shortcut was doing its normal job:
        // no tap, no double tap, and it does not start a double-tap window.
        if usedInShortcut {
            lastTapTime.removeValue(forKey: bindKey)
            secondTapPressed.remove(bindKey)
            return
        }
        // Released before the hold threshold: this press is a tap.
        if binding.doubleTapOutputs != nil {
            let window = Double(max(100, min(2000, binding.doubleTapWindowMs ?? 300))) / 1000.0
            if secondTapPressed.remove(bindKey) != nil
                || lastTapTime[bindKey].map({ now - $0 <= window }) == true {
                // Second tap inside the window: the double action fires and
                // the pending single-tap is canceled via the token bump.
                lastTapTime.removeValue(forKey: bindKey)
                pendingSingleTapToken[bindKey, default: 0] += 1
                pulse(binding.doubleTapOutputs ?? [], bindKey: bindKey)
            } else {
                // First tap: wait out the window before firing the single
                // action, in case a second tap arrives.
                lastTapTime[bindKey] = now
                let token = (pendingSingleTapToken[bindKey] ?? 0) + 1
                pendingSingleTapToken[bindKey] = token
                let gen = engineGeneration
                let outputs = binding.outputs
                DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
                    guard let self,
                          self.engineGeneration == gen,
                          self.pendingSingleTapToken[bindKey] == token,
                          self.lastTapTime[bindKey] != nil else { return }
                    self.lastTapTime.removeValue(forKey: bindKey)
                    self.pulse(outputs, bindKey: bindKey)
                }
            }
        } else {
            // Plain tap-vs-hold: the tap action fires as a quick pulse.
            pulse(binding.outputs, bindKey: bindKey)
        }
    }

    /// Fire outputs as a short press-then-release pulse. The release is
    /// generation-guarded like turbo's scheduled release, so a stop()
    /// between the two cannot leave a synthesized key down on a preset
    /// that has moved on (releaseAll in stop() covers the gap).
    private func pulse(_ outputs: [OutputAction], bindKey: String) {
        // Named after the row (its group comes first), so an app action
        // fired later knows which controller pressed it.
        let owner = bindKey + "#pulse-" + UUID().uuidString
        fireOutputs(outputs, press: true, owner: owner)
        let gen = engineGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.engineGeneration == gen else { return }
            self.fireOutputs(outputs, press: false, owner: owner)
        }
    }

    /// bindKeys whose running macro chain should stop at the next press hop.
    /// Set by the release transition when the binding opts into
    /// macroInterruptOnRelease; consumed (and cleared) by executeMacro.
    private var macroCancelRequests: Set<String> = [] {
        // Mirrored for the chain threads, which wait between steps and
        // have to see a release at once (see MacroCancelFlags).
        didSet { MacroCancelFlags.shared.set(macroCancelRequests) }
    }

    /// Ask a running chain to stop. Reads on the main actor only.
    func requestMacroCancel(bindKey: String) {
        macroCancelRequests.insert(bindKey)
    }

    private func executeMacro(_ steps: [MacroStep], joystickIndex: Int, bindKey: String,
                              repeatCount: Int = 1, repeatDelayMs: Int = 0) {
        StatsService.shared.recordMacroExecution()
        if debugEnabled { log("MACRO: executing \(steps.count) steps", joystick: joystickIndex) }
        let scheduledGen = engineGeneration
        let repeats = max(1, min(100, repeatCount))
        // One counter for every row, so a token is never handed out twice
        // even after a row's entry was dropped.
        macroChainCounter &+= 1
        let chainToken = macroChainCounter
        macroChainToken[bindKey] = chainToken
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            // Set when a press hop observes a generation change (engine
            // stopped or preset switched): the rest of the chain exits
            // instead of sleeping out its full duration, and no further
            // releases fire for presses that never happened.
            var chainAbandoned = false
            // Actions pressed by .down steps that have not been released by a
            // matching .up step yet. Anything left when the chain ends (or is
            // abandoned) gets released so a chord can never stay stuck.
            // Each with the owner of the step that pressed it: every step
            // presses under its own owner, so a later step pressing and
            // releasing Shift does not let go of a Shift a Down step holds.
            var heldActions: [(action: OutputAction, owner: String)] = []
            // The wait the row shows between repeats, which the macro used
            // to ignore. Clamped like everything else here.
            let between = min(Double(max(0, repeatDelayMs)) / 1000.0, 30.0)
            outer: for pass in 0..<repeats {
                if pass > 0, between > 0 { MacroCancelFlags.shared.sleep(between, row: bindKey) }
                for (stepIndex, step) in steps.enumerated() {
                    guard self != nil, !chainAbandoned else { break outer }
                    let stepOwner = bindKey + "#macro#\(chainToken)#\(stepIndex)"
                    // Pre-step delay (clamped to 30s).
                    if step.delayMs > 0 {
                        let secs = min(Double(step.delayMs) / 1000.0, 30.0)
                        MacroCancelFlags.shared.sleep(secs, row: bindKey)
                    }
                    let kind = step.eventKind ?? .tap

                    // A Release step lets go of an earlier held action. The
                    // release fires regardless of generation (scoped, safe)
                    // and the step has no press/hold phase of its own.
                    // A step can be a shortcut (its modifiers with its key);
                    // everything it presses goes down and up together.
                    let actions = step.pressedActions
                    if kind == .up {
                        // Released by whichever Down step pressed it.
                        let serialized = Set(actions.map(\.serialized))
                        let releasing = heldActions.filter { serialized.contains($0.action.serialized) }
                        heldActions.removeAll { serialized.contains($0.action.serialized) }
                        let unmatched = actions.filter { a in !releasing.contains { $0.action.serialized == a.serialized } }
                        DispatchQueue.main.async { [weak self] in
                            for held in releasing { self?.fireOutputs([held.action], press: false, owner: held.owner) }
                            if !unmatched.isEmpty { self?.fireOutputs(unmatched, press: false, owner: stepOwner) }
                        }
                        continue
                    }

                    // Press - guard generation and cancel requests on main
                    // where they are safe to read. The semaphore makes the
                    // press outcome visible to this thread (signal/wait
                    // orders the memory access) before the hold sleep starts;
                    // the box exists only to satisfy strict concurrency
                    // checking for that pattern.
                    let outcome = MacroPressOutcome()
                    let pressGate = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { [weak self] in
                        if let self,
                           self.engineGeneration == scheduledGen,
                           self.macroChainToken[bindKey] == chainToken,
                           !self.macroCancelRequests.contains(bindKey) {
                            self.fireOutputs(actions, press: true, owner: stepOwner)
                            outcome.didPress = true
                        }
                        pressGate.signal()
                    }
                    pressGate.wait()
                    let didPress = outcome.didPress
                    // Hold (clamped to 30s).
                    if step.holdMs > 0 {
                        let secs = min(Double(step.holdMs) / 1000.0, 30.0)
                        MacroCancelFlags.shared.sleep(secs, row: bindKey)
                    }
                    if didPress {
                        if kind == .down {
                            // Stay held for the following steps (chords).
                            heldActions.append(contentsOf: actions.map { ($0, stepOwner) })
                        } else {
                            // Release ONLY this step's output, whether or not
                            // the generation still matches by now: a macro
                            // mid-hold that gets shut down by stop() must not
                            // leave a synthesized key permanently down. Scoped
                            // to the step, so a mid-macro preset switch cannot
                            // drop the NEXT preset's freshly-pressed keys the
                            // way a global releaseAll here once did.
                            DispatchQueue.main.async { [weak self] in
                                self?.fireOutputs(Array(actions.reversed()), press: false, owner: stepOwner)
                            }
                        }
                    } else {
                        // Press was skipped (generation changed or the user
                        // released with stop-on-release): firing the release
                        // anyway could drop an input the next preset is
                        // legitimately holding. Exit the chain.
                        chainAbandoned = true
                    }
                }
            }
            // Let go of anything a .down step left held, newest first, so an
            // abandoned or unbalanced chain cannot leave a chord stuck.
            if !heldActions.isEmpty {
                let leftovers = Array(heldActions.reversed())
                DispatchQueue.main.async { [weak self] in
                    for held in leftovers {
                        self?.fireOutputs([held.action], press: false, owner: held.owner)
                    }
                }
            }
            // Chain done or abandoned; clear the in-flight flag so the next
            // press can fire a fresh macro execution, and drop any unconsumed
            // cancel request so it cannot abort a future chain.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.macroChainToken[bindKey] == chainToken else { return }
                self.macrosInFlight.remove(bindKey)
                self.macroCancelRequests.remove(bindKey)
            }
        }
    }

    /// Execute outputs with repeat count.
    ///
    /// Repeat count is clamped to 10 000 and delay to 30 s to bound the
    /// worst-case from an adversarial / malformed preset. Each fire
    /// hop checks `engineGeneration` against the value captured at
    /// schedule time so an active repeat won't leak past stop().
    private func fireWithRepeat(_ binding: BindingModel, bindKey: String) {
        // One run per row at a time: pressing again mid-run used to start a
        // second chain whose presses interleaved with the first.
        guard repeatsInFlight[bindKey] == nil else { return }
        let count = max(1, min(10_000, binding.repeatCount ?? 1))
        let delaySecs = min(Double(binding.repeatDelayMs ?? 100) / 1000.0, 30.0)
        repeatRunCounter &+= 1
        repeatsInFlight[bindKey] = repeatRunCounter
        repeatStep(0, of: count, delay: delaySecs, outputs: binding.outputs,
                   bindKey: bindKey, generation: engineGeneration, run: repeatRunCounter)
    }

    /// Rows running a repeat, by bindKey, with the run's number. An old run
    /// ended by a pause or reload clears the entry only while it is still
    /// its own, so it cannot free the row for a third, overlapping run.
    private var repeatsInFlight: [String: Int] = [:]
    private var repeatRunCounter = 0

    /// One press and release of a repeat, then the next after the delay.
    /// Timed on the main queue rather than a sleeping background thread,
    /// which held a thread for the whole run (minutes, at 100 repeats 5 s
    /// apart), and every hop checks the generation, so Stop and the
    /// emergency stop end the run.
    private func repeatStep(_ i: Int, of count: Int, delay: Double, outputs: [OutputAction],
                            bindKey: String, generation: Int, run: Int) {
        func endRun() { if repeatsInFlight[bindKey] == run { repeatsInFlight.removeValue(forKey: bindKey) } }
        // The run's own entry too: a controller that disconnects drops its
        // groups' entries, and a run with 100 presses 500 ms apart kept
        // clicking for 50 seconds after the pad was gone.
        guard engineGeneration == generation, repeatsInFlight[bindKey] == run else { endRun(); return }
        let owner = bindKey + "#repeat"
        // A run of 2 or 3 is a double or triple click (the double-click
        // presets repeat a click twice). A longer run is a string of single
        // clicks, as turbo sends: counted on, Repeat 10 on Left Click opened
        // a Finder file over and over.
        firingTurboPulse = count > 3
        fireOutputs(outputs, press: true, owner: owner)
        firingTurboPulse = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard self.engineGeneration == generation else { endRun(); return }
            self.fireOutputs(outputs, press: false, owner: owner)
            guard i + 1 < count else { endRun(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.repeatStep(i + 1, of: count, delay: delay, outputs: outputs,
                                 bindKey: bindKey, generation: generation, run: run)
            }
        }
    }

    private func fireContinuousOutputs(_ outputs: [OutputAction], input: InputEvent, state: ControllerState, binding: BindingModel? = nil) {
        var outputs = outputs
        if outputsBlocked {
            guard pointerOnly else { return }
            if pointerWhileEditing, !pointerOnlyAtLockScreen, !pollingSteamGroup, Self.touchpadSetupOpen,
               input.type == .touchpad || input.type == .touchpadGesture { return }
            outputs = outputs.filter { Self.pointerOutputTypes.contains($0.type) }
        }
        for output in outputs {
            switch output.type {
            case .mouseMotion:
                let axis = output.resolvedMouseAxis, dir = output.resolvedMouseDirection
                let speed = output.speed ?? 6

                // Variable sensitivity defaults to true for axis input (gives natural feel).
                // When false, output fires at full speed once the axis crosses the deadzone.
                let useVariable = binding?.variableSensitivity ?? (input.type == .axis || input.type == .touchpad || input.type == .motion || input.type == .midi)

                var magnitude: Float = 1.0
                var signedMagnitude: Float = 1.0   // for touchpad / motion: sign indicates direction of motion
                if useVariable, input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    axisValue = smoothedAxis(axisValue, joystick: pollingJoystickIndex, axis: input.index)
                    // Only this row's half of the stick: a toggled-on row runs
                    // every frame, and the other half moved it its own way.
                    if input.axisDirection == .positive { axisValue = max(0, axisValue) }
                    else if input.axisDirection == .negative { axisValue = min(0, axisValue) }
                    let rawMag = min(abs(axisValue), 1.0)
                    // Apply inner/outer deadzone remap before the curve so
                    // the curve operates on the post-deadzone normalized
                    // 0...1 range, not the raw analog value.
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                } else if input.type == .touchpad,
                          let tpAxis = input.touchpadAxis {
                    let finger = input.touchpadFinger ?? input.index
                    // Touchpad already reports a per-frame delta; we don't
                    // need to remap by a deadzone here. Sign carries motion
                    // direction. Use a much larger gain than axes because
                    // delta values are typically very small (a fraction of
                    // surface width per frame).
                    // peek, not consume: the per-frame delta is drained once at
                    // the end of pollControllers so multiple bindings on the
                    // same finger+axis all read the same motion.
                    let surface = input.touchpadSurface ?? 0
                    var delta = touchService(surface).peekDelta(finger: finger, axis: tpAxis)
                    if binding?.invertAxis == true { delta = -delta }
                    // A vertical row recorded before 1.6 moves as it did then,
                    // when each axis was divided by its own span.
                    if tpAxis == .y, let b = binding, LegacyRowCheck.isOlderRow(b) {
                        delta *= touchService(surface).legacyVerticalScale
                    }
                    // The finger's movement since the last poll, turned into
                    // a rate by the time that poll actually took, so a late
                    // poll does not arrive as a lurch. Lightly filtered like
                    // the sticks: touch sampling is coarse and a finger
                    // never moves in a straight line at one speed.
                    delta = delta / frameScale
                    delta = smoothedAxis(delta, joystick: pollingJoystickIndex,
                                         axis: 300 + surface * 4 + finger * 2 + (tpAxis == .x ? 0 : 1))
                    // Filter by requested half-axis: + means motion in the
                    // positive direction counts, motion in the other direction
                    // is ignored. This lets users bind "swipe right" → mouse
                    // right and "swipe left" → mouse left independently.
                    switch input.axisDirection {
                    case .positive: if delta < 0 { delta = 0 }
                    case .negative: if delta > 0 { delta = 0 }
                    case .none: break
                    }
                    // Touchpad speed multiplier - delta is in [-1, 1] roughly
                    // per second of motion; scale so a normal swipe moves the
                    // cursor a healthy distance.
                    let gain: Float = 80.0
                    signedMagnitude = delta * gain
                    magnitude = abs(signedMagnitude)
                }

                // Ramp-up: a stick row with rampMs starts slow and eases to full
                // speed over that long, whether or not its speed follows the
                // stick's depth.
                if input.type == .axis, let b = binding, b.rampMs != nil {
                    if magnitude > 0 { magnitude *= rampFactor(for: b) }
                }

                // Motion moves the pointer by the angle the controller turned
                // this poll, not by its rate. Pixels = radians x gain, so a
                // tilt and its reverse cancel exactly and the pointer comes
                // back to where it started, however fast either half was.
                // A positive gyro Y bound to mouse-X+ moves the pointer right;
                // the binding's invertAxis flag flips the polarity.
                if useVariable, input.type == .motion,
                   let channel = input.motionChannel,
                   let rate = state.motion[channel] {
                    var angle: Float
                    var correction: Float = 0
                    var pointing = false
                    if !currentSlotMotionMuted,
                       let pending = pendingTilt(group: pollingJoystickIndex, channel: channel, state: state,
                                                 deadzone: binding?.deadzone) {
                        // Position control: send whatever offset is still
                        // owed. The row that owns this sign of movement
                        // sends it and records it as emitted; the other
                        // row then sees nothing left to do this poll.
                        pointing = true
                        angle = binding?.invertAxis == true ? -pending : pending
                    } else {
                        angle = state.motionAngle[channel] ?? (rate * frameScale / 120)
                        correction = state.motionCorrection[channel] ?? 0
                        if binding?.invertAxis == true { angle = -angle; correction = -correction }
                    }
                    if pointing {
                        // Half-axis ownership, then book the emitted share.
                        switch input.axisDirection {
                        case .positive: if angle < 0 { angle = 0 }
                        case .negative: if angle > 0 { angle = 0 }
                        case .none: break
                        }
                        // What is owed is already smoothed (the row's
                        // deadzone sets how strongly; see TiltPointer), so
                        // tremor is taken out and a remainder is paid out
                        // over the next few polls, never in one lump. The
                        // tightening that used to sit here held a slow
                        // movement's share back and then paid all of it on
                        // the next quick one: a jump. Under half a pixel
                        // waits, so a resting controller never twitches the
                        // pointer by a pixel back and forth. Only what is
                        // sent is booked; the rest stays owed, so the
                        // pointer comes back to its anchor when the
                        // controller does.
                        if abs(angle) * 160 * Float(speed) < 0.5 { angle = 0 }
                        if angle != 0 {
                            let signedSent = binding?.invertAxis == true ? -angle : angle
                            pitchAnchors[anchorKey(pollingJoystickIndex, channel)]?.book(signedSent)
                        }
                        signedMagnitude = angle * 160 * Float(speed)
                        magnitude = abs(signedMagnitude)
                    } else if currentSlotMotionMuted {
                        // Gyro ratchet held: re-aim without moving the pointer.
                        // For pitch the anchor moves with the controller so
                        // release does not snap back.
                        signedMagnitude = 0; magnitude = 0
                        pitchAnchorReset = true
                    } else {
                    // Tightening (the standard gyro-aim treatment for a hand
                    // that is never perfectly still): below the row's
                    // deadzone the movement is scaled down smoothly in
                    // proportion to how slow it is, so tremor barely moves
                    // the pointer while a deliberate slow tilt still does.
                    // Nothing is cut outright except pure sensor noise.
                    let tightenBelow = max(0.005, binding?.deadzone ?? 0.05)
                    if abs(rate) < 0.005 {
                        angle = 0
                    } else if abs(rate) < tightenBelow {
                        angle *= abs(rate) / tightenBelow
                    }
                    // The accelerometer anchor's share goes through as is.
                    angle += correction
                    // Filter by half-axis like we do for touchpad.
                    switch input.axisDirection {
                    case .positive: if angle < 0 { angle = 0 }
                    case .negative: if angle > 0 { angle = 0 }
                    case .none: break
                    }
                    // Same feel as before: at Speed 6 one radian of turn is
                    // about 960 px, a degree about 17 px.
                    signedMagnitude = angle * 160 * Float(speed)
                    magnitude = abs(signedMagnitude)
                    }
                }

                // MIDI dials feed the analog mouse path the way a stick
                // does: midiAxisValue is signed for centered sources, the
                // half-axis direction filters which side of the dial this
                // binding responds to, and the shared deadzone remap plus
                // sensitivity curve shape the response.
                if useVariable, input.type == .midi, var v = midiAxisValue(input) {
                    if binding?.invertAxis == true { v = -v }
                    switch input.axisDirection {
                    case .positive: if v < 0 { v = 0 }
                    case .negative: if v > 0 { v = 0 }
                    case .none: break
                    }
                    let rawMag = min(abs(v), 1.0)
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                }

                let scaledSpeed: Float
                if input.type == .motion {
                    // Already whole pixels for this poll (angle x gain); no
                    // further speed scaling. NaN guard as below.
                    scaledSpeed = signedMagnitude.isFinite ? abs(signedMagnitude) : 0
                } else if input.type == .touchpad {
                    // signedMagnitude already encodes direction + speed;
                    // mouseDirection picks which CGEvent axis it adds to.
                    // Guard against NaN/Inf: an uncalibrated DualSense
                    // can briefly publish NaN motion samples right
                    // after connect, and Float(.nan) accumulation would
                    // poison the carry.
                    let raw = abs(signedMagnitude) * Float(speed) / 6.0
                    scaledSpeed = raw.isFinite ? raw : 0
                } else {
                    let raw = Float(speed) * magnitude
                    scaledSpeed = raw.isFinite ? raw : 0
                }
                // Everything reaches the pump as a rate: sticks and dials by
                // position, the gyroscope by angular rate, the touchpad by
                // finger movement over the poll interval.
                // The touchpad's displacement was turned into a rate above,
                // so it takes the pump path too. Motion is the exception: it
                // is an exact pixel delta for this poll and goes straight to
                // the frame accumulator, so nothing between the sensor and
                // the pointer can round a movement and its reverse apart.
                let isRate = input.type != .motion
                switch (axis, dir, isRate) {
                case (.horizontal, .positive, false): pendingMotionDeltaX += scaledSpeed
                case (.horizontal, .negative, false): pendingMotionDeltaX -= scaledSpeed
                case (.vertical, .positive, false): pendingMotionDeltaY += scaledSpeed
                case (.vertical, .negative, false): pendingMotionDeltaY -= scaledSpeed
                case (.horizontal, .positive, true): pendingMouseRateX += scaledSpeed
                case (.horizontal, .negative, true): pendingMouseRateX -= scaledSpeed
                case (.vertical, .positive, true): pendingMouseRateY += scaledSpeed
                case (.vertical, .negative, true): pendingMouseRateY -= scaledSpeed
                }

            case .mouseWheel:
                let axis = output.resolvedMouseAxis, dir = output.resolvedMouseDirection
                let speed = output.speed ?? 6

                let useVariable = binding?.variableSensitivity ?? (input.type == .axis || input.type == .midi)

                var magnitude: Float = 1.0
                if useVariable, input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    axisValue = smoothedAxis(axisValue, joystick: pollingJoystickIndex, axis: input.index)
                    // Only this row's half of the stick: a toggled-on row runs
                    // every frame, and the other half moved it its own way.
                    if input.axisDirection == .positive { axisValue = max(0, axisValue) }
                    else if input.axisDirection == .negative { axisValue = min(0, axisValue) }
                    let rawMag = min(abs(axisValue), 1.0)
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                }
                // MIDI dial: scroll speed proportional to how far off
                // center the knob sits, same shaping as the mouse path.
                if useVariable, input.type == .midi, var v = midiAxisValue(input) {
                    if binding?.invertAxis == true { v = -v }
                    switch input.axisDirection {
                    case .positive: if v < 0 { v = 0 }
                    case .negative: if v > 0 { v = 0 }
                    case .none: break
                    }
                    let rawMag = min(abs(v), 1.0)
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                }

                // Same NaN guard as the mouse-motion path above. Stick-driven
                // scrolling is time-scaled like the pointer; a dial's value is
                // a position, not a rate, and is left alone.
                let rawScroll = Float(speed) * magnitude
                // Clamp before Int32(): an absurd imported scroll speed would
                // otherwise trap even though isFinite is true.
                let scaledSpeed = rawScroll.isFinite
                    ? max(-1_000_000, min(1_000_000, rawScroll)) : 0
                // Every scroll source is a rate while it is active (a stick
                // or dial by its position, a touchpad finger while it moves),
                // and goes to the pump.
                let scrollIsRate = true
                switch (axis, dir, scrollIsRate) {
                case (.horizontal, .positive, false): pendingScrollDeltaX += scaledSpeed
                case (.horizontal, .negative, false): pendingScrollDeltaX -= scaledSpeed
                case (.vertical, .positive, false): pendingScrollDeltaY += scaledSpeed
                case (.vertical, .negative, false): pendingScrollDeltaY -= scaledSpeed
                case (.horizontal, .positive, true): pendingScrollRateX += scaledSpeed
                case (.horizontal, .negative, true): pendingScrollRateX -= scaledSpeed
                case (.vertical, .positive, true): pendingScrollRateY += scaledSpeed
                case (.vertical, .negative, true): pendingScrollRateY -= scaledSpeed
                }

            case .absoluteVolume:
                // Fader semantics: the system volume tracks the input's
                // absolute position - but only once the user MOVES the
                // control. On activation the control's resting position is
                // recorded as a baseline and nothing happens; the fader
                // engages when the position travels 2% from that baseline,
                // so activating a preset never yanks the volume to
                // wherever a knob was left. Intentional movement is the
                // consent. The setter drops sub-epsilon changes, so a
                // resting control costs nothing per frame.
                if let position = absolutePosition(for: input, state: state) {
                    if let id = binding?.id {
                        if let baseline = faderBaseline[id] {
                            if !faderEngaged.contains(id), abs(position - baseline) > 0.02 {
                                faderEngaged.insert(id)
                            }
                        } else {
                            faderBaseline[id] = position
                        }
                        guard faderEngaged.contains(id) else { continue }
                    }
                    SystemVolumeService.shared.setVolume(position)
                }

            case .midiCC:
                // Continuous axis driving a CC. Map the axis's full range to
                // 0..127. For positive-only inputs (triggers, axis "positive"
                // direction) we map 0..1 to 0..127. For full-range axes we
                // map -1..1 to 0..127.
                guard input.type == .axis, var axisValue = state.axes[input.index] else { continue }
                if binding?.invertAxis == true { axisValue = -axisValue }

                let ccValue: Int
                // Through the deadzones first, so the low end is reachable:
                // a 0.25 deadzone used to make 0 to 31 impossible to send.
                if input.axisDirection == .positive {
                    var mag = remapMagnitude(max(0, min(1, axisValue)), binding: binding)
                    if let curve = binding?.sensitivityCurve { mag = abs(curve.apply(mag)) }
                    ccValue = Int((mag * 127).rounded())
                } else if input.axisDirection == .negative {
                    var mag = remapMagnitude(max(0, min(1, -axisValue)), binding: binding)
                    if let curve = binding?.sensitivityCurve { mag = abs(curve.apply(mag)) }
                    ccValue = Int((mag * 127).rounded())
                } else {
                    // Full-range axis: -1..1 maps to 0..127
                    let normalized = (axisValue + 1) / 2
                    // Rounded, so center is 64, the value its release sends.
                    ccValue = Int((max(0, min(1, normalized)) * 127).rounded())
                }
                let cc = output.midiCCNumber ?? 1
                let ch = output.midiChannel ?? 1
                MIDIService.shared.sendCC(controller: cc, value: ccValue, channel: ch)

            case .midiPitchBend:
                // Pitch bend is signed and centered at 8192. -1..1 maps to 0..16383.
                guard input.type == .axis, var axisValue = state.axes[input.index] else { continue }
                if binding?.invertAxis == true { axisValue = -axisValue }
                var v: Float
                // Half axes go through the deadzones first, as CC does, so
                // the first part of the bend past a deadzone is reachable.
                if input.axisDirection == .positive {
                    v = remapMagnitude(max(0, min(1, axisValue)), binding: binding)
                } else if input.axisDirection == .negative {
                    v = -remapMagnitude(max(0, min(1, -axisValue)), binding: binding)
                } else {
                    v = max(-1, min(1, axisValue))
                }
                if let curve = binding?.sensitivityCurve {
                    let mag = curve.apply(abs(v))
                    v = v >= 0 ? mag : -mag
                }
                // Centered on 8192, the value a release sends.
                let pbValue = max(0, min(16383, 8192 + Int((v * 8191).rounded())))
                let ch = output.midiChannel ?? 1
                MIDIService.shared.sendPitchBend(value: pbValue, channel: ch)

            default:
                break
            }
        }
    }

    // MARK: - Feedback (Haptics + Speech)

    /// Fire haptic and speech feedback for a binding press event.
    private func fireFeedback(for binding: BindingModel, joystickIndex: Int) {
        if outputsBlocked { return }
        // The controller this group reads, which need not be the one at the
        // group's own index.
        let slot = slotForGroup[joystickIndex] ?? joystickIndex
        if binding.hapticEnabled == true,
           controllerService.connectedControllers.indices.contains(slot) {
            let controller = controllerService.connectedControllers[slot]
            let intensity = binding.hapticIntensity ?? 0.6
            FeedbackService.shared.vibrate(controller: controller, intensity: intensity,
                                           durationMs: binding.hapticDurationMs ?? FeedbackService.defaultDurationMs)
        } else if binding.hapticEnabled == true, let pad = controllerService.rawHIDGamepadSlots[slot],
                  pad.profile?.layout == .steamController2026 {
            // The 2026 Steam Controller's motors, through its own report.
            RawHIDGamepadService.shared.rumbleSteamController2026(
                gamepadID: pad.id, intensity: binding.hapticIntensity ?? 0.6,
                durationMs: binding.hapticDurationMs ?? FeedbackService.defaultDurationMs)
        }

        if binding.speechEnabled == true {
            let phrase = binding.speechText?.isEmpty == false
                ? binding.speechText!
                : binding.input.serialized
            let destination = binding.speechDestination ?? .mac
            FeedbackService.shared.speak(phrase, destination: destination)
        }
    }
}

/// Carries a macro step's press outcome from the main-queue hop back to the
/// macro's background thread. The DispatchSemaphore signal/wait pair in
/// executeMacro orders the write before the read; this box exists because
/// strict concurrency checking cannot see that ordering on a captured var.
private final class MacroPressOutcome: @unchecked Sendable {
    var didPress = false
}

/// The rows whose stop-on-release macro was let go, readable from the
/// macro chain threads. A chain waiting out a step's hold or delay (up to
/// 30 s) kept its keys down that long after the button came up, though the
/// editor says letting go stops the rest and releases what is held.
final class MacroCancelFlags: @unchecked Sendable {
    static let shared = MacroCancelFlags()
    private let lock = NSLock()
    private var rows: Set<String> = []
    func set(_ value: Set<String>) { lock.lock(); rows = value; lock.unlock() }
    func contains(_ row: String) -> Bool { lock.lock(); defer { lock.unlock() }; return rows.contains(row) }

    /// Sleep up to `seconds`, waking early once `row` is let go.
    func sleep(_ seconds: Double, row: String) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if contains(row) { return }
            Thread.sleep(forTimeInterval: min(0.02, end.timeIntervalSinceNow))
        }
    }
}

/// Runtime engine for `DriveConfig`: converts one analog stick into a full
/// vehicle control scheme (steering + throttle/brake) with a Drive/Reverse
/// gear gesture. Holds the per-frame state (gear, PWM phase, pressed keys,
/// gesture history) so the MappingEngine poll loop stays clean. Throttle
/// keys are emitted through InputSimulator; steering-by-mouse is returned to
/// the caller so it can be merged into the engine's mouse-delta accumulator.
final class DriveModeProcessor {
    enum Gear { case drive, reverse }
    private(set) var gear: Gear = .drive

    /// Live telemetry for on-screen feedback, refreshed every process() call.
    struct LiveState: Equatable {
        var reverse = false
        var throttle: Float = 0   // 0-1 forward power being applied
        var brake: Float = 0      // 0-1 brake / backward
        var steer: Float = 0      // -1..1 after curve
    }
    private(set) var liveState = LiveState()

    private var pressed = Set<Int>()
    private var pwmTick: [Int: Int] = [:]
    private var backHits: [Double] = []
    private var wasAtBackWall = false
    /// When the throttle was last applied, for the coast brake window.
    private var lastThrottleAt: Double = -.infinity
    private static let coastBrakeSeconds: Double = 3
    /// The trigger-style throttle has been seen below -0.5: a pedal that
    /// reads -1 to 1 (a Thrustmaster or Fanatec wheel, a standalone pedal
    /// set), not a 0 to 1 trigger, so its whole travel is mapped to 0...1.
    private var throttleIsBipolar = false

    /// Process one poll frame. Returns the steering mouse-X delta (pixels)
    /// to add to the engine's pending mouse delta; 0 when steering by keys.
    @discardableResult
    func process(_ cfg: DriveConfig, axisX: Float, axisY: Float, now: Double) -> Float {
        var x = axisX; if cfg.invertSteer { x = -x }
        // Stick up is negative everywhere in the app, and forward is up. A
        // trigger already reads 0 at rest to 1 pulled.
        var y = cfg.throttleIsTrigger ? axisY : -axisY; if cfg.invertThrottle { y = -y }
        let dz = Float(cfg.deadzone)
        let steer = deadzoned(x, dz)

        // Forward / backward throttle components. A trigger-style axis rests
        // at one end (no center, no backward): map its whole range to forward.
        let fwd: Float, back: Float
        if cfg.throttleIsTrigger {
            // Trigger axes normalize to 0...1 resting at 0 everywhere in this
            // app (GC buttonInput.value, HID byte/255, Steam byte/255), so use
            // the value directly. The old (y+1)/2 remap assumed a -1...1 trigger
            // and left the accelerator held at ~43% with the trigger released.
            if y < -0.5 { throttleIsBipolar = true }
            fwd = max(0, deadzoned(throttleIsBipolar ? (y + 1) / 2 : y, dz))
            back = 0
        } else {
            fwd = max(0, deadzoned(y, dz))
            back = max(0, deadzoned(-y, dz))
        }
        if fwd > 0.001 { lastThrottleAt = now }

        // Gear / reverse gesture: count rising-edge "wall hits" at full back.
        // Disabled for trigger axes (they have no backward deflection).
        var shiftedToDriveThisFrame = false
        if cfg.reverseGestureEnabled && !cfg.throttleIsTrigger {
            let thr = Float(cfg.gestureThreshold)
            let atWall = back >= thr
            if atWall && !wasAtBackWall { backHits.append(now) }
            wasAtBackWall = atWall
            let window = Double(cfg.reverseWindowMs) / 1000.0
            backHits.removeAll { now - $0 > window }
            if gear == .drive && backHits.count >= max(1, cfg.reverseTapCount) {
                gear = .reverse; backHits.removeAll()
            }
            if gear == .reverse && fwd >= thr {   // full forward returns to Drive
                gear = .drive; backHits.removeAll()
                shiftedToDriveThisFrame = true
            }
        } else {
            gear = .drive
        }

        // Accumulate the desired duty per HID code so a code used by more than
        // one role (a shared steer/throttle key) is pulsed exactly ONCE with
        // its max duty, never double-advancing its PWM phase or fighting itself.
        var want: [Int: Float] = [:]
        func request(_ code: Int, _ d: Float) { if d > (want[code] ?? 0) { want[code] = d } }

        // Steering (with its own response curve, sign preserved).
        let steerShaped = signed(curve(abs(steer), Float(cfg.steerCurve)), steer)
        var steerMouseDX: Float = 0
        if cfg.steerMode == .mouse {
            steerMouseDX = steerShaped * Float(cfg.steerMouseSpeed)
        } else {
            request(cfg.steerLeftKey, steerShaped < 0 ? abs(steerShaped) : 0)
            request(cfg.steerRightKey, steerShaped > 0 ? abs(steerShaped) : 0)
        }

        // Throttle / brake by gear. PWM gives variable speed on a binary key:
        // duty scales with how far the stick is pushed. Skipped on the exact
        // frame the full-forward gesture shifts Reverse -> Drive so the stale
        // full-forward reading doesn't also slam the accelerator (no lurch).
        let exp = Float(cfg.throttleCurve)
        let cf = curve(fwd, exp)
        let cb = curve(back, exp)
        if !shiftedToDriveThisFrame {
            switch gear {
            case .drive:
                request(cfg.accelKey, cf)
                request(cfg.brakeKey, cb)
                // Active slow-down: when the stick is centered (no throttle,
                // no brake) hold a light brake so the vehicle decelerates
                // instead of coasting. `request` takes the max, so this never
                // fights a real throttle or brake input.
                // Only while the car is still rolling: for a few seconds after
                // the throttle let go. Held for good, it tapped S forever at
                // rest, which most games read as reverse.
                if cfg.coastBrake && fwd <= 0.001 && back <= 0.001 && now - lastThrottleAt < Self.coastBrakeSeconds {
                    request(cfg.brakeKey, Float(min(max(cfg.coastBrakeStrength, 0), 1)))
                }
            case .reverse:
                request(cfg.reverseKey, cf)
                request(cfg.brakeKey, cb)
            }
        }

        // Apply once per unique HID code this config can touch (unrequested
        // codes get duty 0 and are released).
        let codes: Set<Int> = [cfg.accelKey, cfg.brakeKey, cfg.reverseKey,
                               cfg.steerLeftKey, cfg.steerRightKey]
        for code in codes { pwm(code, want[code] ?? 0, cfg) }

        liveState = LiveState(reverse: gear == .reverse,
                              throttle: shiftedToDriveThisFrame ? 0 : cf,
                              brake: shiftedToDriveThisFrame ? 0 : cb,
                              steer: steerShaped)
        return steerMouseDX
    }

    /// Release every held key and clear gear/gesture state. Call when drive
    /// turns off, outputs pause, or the preset stops.
    func releaseAll() {
        // Read again from the next frame: a bipolar pedal at rest reads -1 at once.
        throttleIsBipolar = false
        for code in pressed { InputSimulator.shared.keyUp(code) }
        pressed.removeAll()
        pwmTick.removeAll()
        backHits.removeAll()
        wasAtBackWall = false
        gear = .drive
        liveState = LiveState()
    }

    // MARK: - Helpers

    private func deadzoned(_ v: Float, _ dz: Float) -> Float {
        let a = abs(v)
        if a <= dz { return 0 }
        let scaled = (a - dz) / max(0.0001, 1 - dz)
        return v < 0 ? -min(scaled, 1) : min(scaled, 1)
    }

    private func curve(_ v: Float, _ exp: Float) -> Float {
        guard v > 0 else { return 0 }
        return exp == 1 ? min(v, 1) : powf(min(v, 1), max(0.1, exp))
    }

    private func signed(_ mag: Float, _ ref: Float) -> Float { ref < 0 ? -mag : mag }

    private func setKey(_ code: Int, _ down: Bool) {
        let isDown = pressed.contains(code)
        if down && !isDown {
            InputSimulator.shared.keyDown(code); pressed.insert(code)
        } else if !down && isDown {
            InputSimulator.shared.keyUp(code); pressed.remove(code)
        }
    }

    /// Pulse a key on/off so its average hold time tracks `duty` (0-1).
    private func pwm(_ code: Int, _ duty: Float, _ cfg: DriveConfig) {
        if duty <= 0.02 { setKey(code, false); pwmTick[code] = 0; return }
        if duty >= 0.98 { setKey(code, true); return }
        let period = max(2, cfg.pwmPeriodTicks)
        // Clamp on-ticks to period-1 so any duty below the 0.98 cutoff keeps
        // at least one off-tick (no silent dead-band that reads as full hold).
        let onTicks = min(period - 1, max(1, Int((duty * Float(period)).rounded())))
        let t = (pwmTick[code] ?? 0) % period
        setKey(code, t < onTicks)
        pwmTick[code] = (t + 1) % period
    }
}

/// Live one-stick drive readout (gear, throttle), for the drive section.
@MainActor
final class DriveTelemetry: ObservableObject {
    static let shared = DriveTelemetry()
    @Published var state: DriveModeProcessor.LiveState?
}

/// One tilt channel's pointing state: the angle the pointer is anchored
/// to, how much of the offset from it the pointer has been sent, and a
/// filter between the raw offset and what is sent.
///
/// The filter is the adaptive low pass commonly used for pointing (the "one
/// euro" filter): the slower the tilt is changing, the lower its cutoff.
/// A hand is never perfectly still, and at Speed 10 a tenth of a degree of
/// tremor is about three pixels, so the raw angle made the pointer shimmer.
/// A resting hand's tremor goes back and forth and so barely raises the
/// filtered speed, and is cut to well under a pixel; a deliberate movement
/// raises the cutoff within a few polls and comes through with a few
/// milliseconds of lag. Because the filter is continuous, whatever has not
/// been sent yet is paid out smoothly over the following polls, never as
/// one jump. Pure value type, for the tests.
struct TiltPointer {
    var anchor: Float
    /// Radians of offset already sent to the pointer.
    var emitted: Float = 0
    /// The smoothed offset from the anchor, radians: where the pointer
    /// should be.
    var target: Float = 0
    /// The offset's smoothed rate of change, radians per second.
    var speed: Float = 0
    var lastOffset: Float = 0
    /// The engine poll that last updated this channel.
    var updatedPoll = Int.min

    /// A row with no deadzone of its own.
    static let defaultDeadzone: Float = 0.05
    /// Cutoff of the speed estimate, Hz.
    static let speedCutoff: Float = 2
    /// How fast the cutoff rises with speed, Hz per radian per second.
    static let speedGain: Float = 20

    init(anchor: Float) { self.anchor = anchor }

    /// The cutoff at rest. The row's deadzone (rad/s, the Motion panel's
    /// band) sets it: the default 0.05 gives 1.2 Hz, a wider band smooths
    /// more, a narrower one less.
    static func restCutoff(deadzone: Float) -> Float {
        min(8, max(0.5, 0.06 / max(0.005, deadzone)))
    }

    static func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    /// One poll: the controller's absolute angle now and the poll's length.
    mutating func update(absolute: Float, dt: Float, deadzone: Float) {
        guard absolute.isFinite, dt.isFinite, dt > 0 else { return }
        let offset = absolute - anchor
        let rawSpeed = (offset - lastOffset) / dt
        lastOffset = offset
        speed += (rawSpeed - speed) * Self.alpha(cutoff: Self.speedCutoff, dt: dt)
        let cutoff = Self.restCutoff(deadzone: deadzone) + Self.speedGain * abs(speed)
        target += (offset - target) * Self.alpha(cutoff: cutoff, dt: dt)
    }

    /// Radians the pointer still has to move to reach `target`.
    var owed: Float { target - emitted }

    /// Record what a row sent.
    mutating func book(_ sent: Float) { emitted += sent }
}
