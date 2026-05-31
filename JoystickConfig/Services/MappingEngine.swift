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
    /// Effective poll rate of the active timer in Hz. Driven by
    /// `installPollTimer()` so the UI (DebugLogView footer, Settings
    /// readout) always shows the *actual* rate, not the saved
    /// default. 120 is the same default we apply in installPollTimer
    /// when no setting is saved yet.
    @Published var currentPollHz: Int = 120
    /// Mirror of currently-active inputs. NOT @Published - observers update
    /// via the throttled `activeInputsPublished` instead so a fast-changing
    /// joystick does not re-render the editor 120 times per second.
    var activeInputs: Set<String> = []
    @Published var activeInputsPublished: Set<String> = []
    private var activeInputsLastFlush: CFTimeInterval = -.infinity
    @Published var debugLog: [(text: String, joystickIndex: Int?)] = []  // Rolling debug log visible in UI

    private var controllerService: GameControllerService
    private var pollTimer: Timer?

    /// Subscription to `ExternalInputDeviceService.events`. Established in
    /// `start()` and cancelled in `stop()` so the engine only listens to
    /// keyboards / mice while a preset is active.
    private var externalEventSubscription: AnyCancellable?
    /// Tracks the last seen power-source label so we can re-install
    /// the poll timer only when the user actually plugs / unplugs.
    /// Without this gate the @Published source string would trigger an
    /// applyPollRate on every IOPS refresh tick (every 5 s).
    private var powerSourceSubscription: AnyCancellable?
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
    private let hatThreshold: Float = 0.5

    // Toggle mode state: tracks which bindings are currently toggled on
    private var toggleStates: [String: Bool] = [:]
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
    // Cache of serialized input keys to avoid repeated string allocations at 120Hz
    private var serializedKeyCache: [UUID: String] = [:]

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
    private var scratchAllActiveSet: Set<String> = []

    private var debugEnabled = true
    private var debugLineCount = 0

    /// Internal buffer the polling loop writes to without triggering UI
    /// re-renders. A separate timer flushes this into `debugLog` (which is
    /// @Published) at a much slower rate so the editor and other observers
    /// of `mappingEngine` do not re-render on every input event.
    private var pendingLog: [(text: String, joystickIndex: Int?)] = []
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
            if outputsPaused {
                // Release any output state that was currently held so the
                // user doesn't end up with a stuck key or held mouse button
                // the moment we pause.
                InputSimulator.shared.releaseAll()
                MIDIService.shared.releaseAllNotes()
                pendingMouseDeltaX = 0
                pendingMouseDeltaY = 0
                pendingScrollDeltaX = 0
                pendingScrollDeltaY = 0
            }
        }
    }

    init(controllerService: GameControllerService) {
        self.controllerService = controllerService
        installControllerDisconnectObserver()
    }

    /// Hook GCControllerDidDisconnect so the engine drops any cached
    /// active-input / toggle / turbo / macro state for that controller
    /// slot. Without this, a controller that disconnects mid-press
    /// leaves orphaned bindKeys in toggleStates + turboTimestamps +
    /// macrosInFlight. When the user reconnects to a different slot
    /// the same UUID is now under a fresh bindKey, but the OLD bindKey
    /// is still flagged "toggled on" - confusing UX because the binding
    /// shows as latched when the user has no way to turn it off. The
    /// normal release path in the poll loop catches simulated outputs,
    /// but not the bindKey-keyed dictionaries.
    private func installControllerDisconnectObserver() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupAfterControllerDisconnect()
            }
        }
    }

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
        let validSlotCount = controllerService.connectedControllers.count
        // Drop activeStates / toggleStates / turboTimestamps / macros
        // for any slot index that no longer corresponds to a connected
        // controller. The dict keys are slot indices for activeStates,
        // and "\(slot):..." strings for the bindKey-keyed ones.
        for slot in activeStates.keys where slot >= validSlotCount {
            activeStates[slot] = nil
        }
        // Clamp the lower bound so an (unrealistic) >32 controller count
        // can't form an inverted Range, which would trap at runtime.
        let prefixes = (min(validSlotCount, 32)..<32).map { "\($0):" }
        for prefix in prefixes {
            toggleStates = toggleStates.filter { !$0.key.hasPrefix(prefix) }
            turboTimestamps = turboTimestamps.filter { !$0.key.hasPrefix(prefix) }
            macrosInFlight = macrosInFlight.filter { !$0.hasPrefix(prefix) }
        }
        // Releasing all simulated outputs is overkill if only one of
        // several connected controllers dropped, but the cost is just
        // a fast pass through the InputSimulator's pressed-keys set
        // - cheaper than tracking which key each slot was holding.
        if validSlotCount == 0 {
            InputSimulator.shared.releaseAll()
            MIDIService.shared.releaseAllNotes()
        }
    }

    // MARK: - Start / Stop

    func start(with preset: Preset) {
        // The original guard required a controller mapping. With external
        // keyboard / mouse inputs we may legitimately have a preset with no
        // controller-shape bindings, so accept anything that has at least
        // one binding anywhere.
        let hasAnyBinding = preset.joysticks.contains { !$0.bindings.isEmpty }
        guard hasAnyBinding else { return }

        activePreset = preset
        isRunning = true
        engineGeneration &+= 1
        activeStates.removeAll()
        activeInputs.removeAll()
        toggleStates.removeAll()
        turboTimestamps.removeAll()
        macrosInFlight.removeAll()
        serializedKeyCache.removeAll()
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

        StatsService.shared.enginStarted(presetName: preset.name)
        log("Engine started with preset: \(preset.name)")
        log("Joysticks: \(preset.joysticks.count), Total bindings: \(preset.joysticks.flatMap(\.bindings).count)")
        log("Connected controllers: \(controllerService.connectedControllers.count)")

        // Spin up the touchpad helper only if the preset actually uses
        // touchpad inputs. Avoids running a subprocess users didn't opt in to.
        let usesTouchpad = preset.joysticks.contains { joystick in
            joystick.bindings.contains {
                $0.input.type == .touchpad || $0.input.type == .touchpadRegion
            }
        }
        if usesTouchpad {
            TouchpadService.shared.retain()
            usesTouchpadInput = true
            log("Touchpad input enabled (started TouchpadHelper)")
        } else {
            usesTouchpadInput = false
        }

        // Cursor-region bindings read the live cursor position. That used
        // to arrive via the system event tap; it now comes from a
        // permission-free NSEvent.mouseLocation poll owned by
        // CursorRegionService. Only start it when the preset actually
        // uses a cursor region, and balance it in stop().
        let usesCursorRegion = preset.joysticks.contains { joystick in
            joystick.bindings.contains { $0.input.type == .cursorRegion }
        }
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

        // Push the preset's light-bar override (if any) so every
        // light-capable controller flashes the preset's color while it's
        // active. We apply temporarily - the slot's stored default color is
        // untouched, so revert in stop() simply re-asserts it.
        if let override = preset.lightBarColor {
            let bri: UInt8? = preset.lightBarBrightness.map { UInt8(max(0, min(2, $0))) }
            for slot in controllerService.controllerDetails.keys
                where controllerService.controllerDetails[slot]?.hasLight == true {
                controllerService.applyTemporaryLight(
                    at: slot,
                    red: override.floatR,
                    green: override.floatG,
                    blue: override.floatB,
                    brightness: bri)
            }
            log("Applied preset light-bar override (\(override.r),\(override.g),\(override.b))")
        }

        // Polling rate is configurable from Settings → General → Polling Rate.
        // Default 120 Hz balances latency vs. UI cost; 240 doubles latency
        // headroom but cascades twice as many @Published mirror writes, so
        // the editor sheet can hitch. 60 cuts CPU in half but feels laggy
        // for fast-twitch inputs. Stored in UserDefaults so it persists.
        installPollTimer()

        // Per-preset automation: apply CursorGuard overrides + auto-
        // launch any app the preset names. Applied BEFORE the cursor-
        // guard engine flag flips so the new settings are already in
        // place when the service activates.
        CursorGuardService.shared.applyPresetOverride(preset.automation)
        applyPresetAutoLaunch(preset.automation)

        // Let the cursor-guard service know the engine is up so it can
        // hide the system cursor / start its recenter loop if the user
        // enabled those toggles.
        CursorGuardService.shared.engineDidChangeState(running: true)

        // Watch power-source transitions so applyPollRate() runs
        // exactly once per plug / unplug when the user has enabled
        // "Auto-switch on power source" in Settings. Retain the
        // SystemStatsService poll timer for the duration so the
        // source field is actually being updated.
        SystemStatsService.shared.retain()
        lastSeenPowerSource = SystemStatsService.shared.power.source
        powerSourceSubscription = SystemStatsService.shared.$power
            .map(\.source)
            .removeDuplicates()
            .sink { [weak self] newSource in
                guard let self = self else { return }
                let auto = UserDefaults.standard
                    .bool(forKey: "JoystickConfig.autoPollHzByPower")
                guard auto, newSource != self.lastSeenPowerSource else { return }
                self.lastSeenPowerSource = newSource
                self.applyPollRate()
            }

        // Subscribe to external keyboard / mouse events for the lifetime of
        // this preset. The IOHIDManager-backed service only delivers events
        // from physical devices, so synthetic CGEvents we post for outputs
        // are naturally filtered out at the HID layer - no input loops.
        let usesExternal = preset.joysticks.contains { joystick in
            joystick.bindings.contains {
                $0.input.type == .extKey || $0.input.type == .extMouse
            }
        }
        if usesExternal {
            externalEventSubscription = ExternalInputDeviceService.shared.events
                .receive(on: DispatchQueue.main)
                .sink { [weak self] event in
                    self?.ingestExternalEvent(event)
                }
            log("External keyboard / mouse input enabled")
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
    /// `JoystickConfig.pollHz` UserDefaults value. Called from start()
    /// during initial install and from `applyPollRate()` when the user
    /// changes the rate in Settings while the engine is already
    /// running. Clamped to [30, 240] to keep CPU sane.
    func installPollTimer() {
        pollTimer?.invalidate()
        let pollHz = resolveEffectivePollHz()
        let pollInterval: TimeInterval = 1.0 / Double(pollHz)
        currentPollHz = pollHz
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
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
    private func resolveEffectivePollHz() -> Int {
        let defaults = UserDefaults.standard
        let autoSwitch = defaults.bool(forKey: "JoystickConfig.autoPollHzByPower")
        let fallback = defaults.object(forKey: "JoystickConfig.pollHz") as? Int ?? 120
        let rate: Int
        if autoSwitch {
            let acRate = defaults.object(forKey: "JoystickConfig.pollHzOnAC") as? Int ?? fallback
            let battRate = defaults.object(forKey: "JoystickConfig.pollHzOnBattery") as? Int ?? 60
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
            currentPollHz = max(30, min(240, UserDefaults.standard.object(forKey: "JoystickConfig.pollHz")
                                        as? Int ?? 120))
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
        StatsService.shared.engineStopped()
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
        macrosInFlight.removeAll()
        serializedKeyCache.removeAll()
        externalEventSubscription?.cancel()
        externalEventSubscription = nil
        externalKeysDown.removeAll()
        externalMouseButtonsDown.removeAll()
        externalMouseDX.removeAll()
        externalMouseDY.removeAll()
        externalScrollDX.removeAll()
        externalScrollDY.removeAll()
        InputSimulator.shared.releaseAll()
        MIDIService.shared.releaseAllNotes()
        if usesTouchpadInput {
            TouchpadService.shared.release()
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
        SystemStatsService.shared.release()

        // Revert any preset light-bar override by re-asserting each
        // light-capable controller's stored slot color. setControllerLight
        // reads from `lightColors` / slot defaults, so the user-configured
        // general color comes back automatically.
        if let preset = activePreset, preset.lightBarColor != nil {
            for slot in controllerService.controllerDetails.keys
                where controllerService.controllerDetails[slot]?.hasLight == true {
                controllerService.setControllerLight(at: slot)
            }
            log("Reverted light bar to general color")
        }

        activeStates.removeAll()
        activeInputs.removeAll()
        activePreset = nil
        log("Engine stopped")
        // Final flush so the user sees the stop event in the log view.
        flushPendingLog()
    }

    // MARK: - Debug Logging

    private func log(_ message: String, joystick: Int? = nil) {
        debugLineCount += 1
        let entry = "[\(debugLineCount)] \(message)"
        // Write to the internal buffer (no @Published trigger). The flush
        // timer copies this into `debugLog` at 5 Hz so observers of the
        // mapping engine do not re-render on every input event.
        pendingLog.append((text: entry, joystickIndex: joystick))
        if pendingLog.count > 50 {
            pendingLog.removeFirst()
        }
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
        guard !pendingLog.isEmpty else { return }
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
    private var pendingMouseDeltaX: Int = 0
    private var pendingMouseDeltaY: Int = 0
    private var pendingScrollDeltaX: Int32 = 0
    private var pendingScrollDeltaY: Int32 = 0

    private func pollControllers() {
        guard let preset = activePreset else { return }
        pollCount += 1
        // Cumulative session counter for the Stats panel - cheap UInt64
        // increment, ignored when the panel isn't subscribed.
        SystemStatsService.shared.recordControllerPolls()
        pendingMouseDeltaX = 0
        pendingMouseDeltaY = 0
        pendingScrollDeltaX = 0
        pendingScrollDeltaY = 0

        // Hoist time-source reads out of the per-binding inner loop.
        // CACurrentMediaTime is a monotonic Double seconds counter with
        // no allocation cost; replaces the Date() that used to be
        // constructed per turbo binding per poll frame.
        let nowMonotonic = CACurrentMediaTime()
        // The raw-state log line and the published-active-inputs flush
        // also wanted a Date(), but they only fire infrequently so we
        // build one lazily inside those branches.
        let shouldLogRawState = (pollCount % 120 == 1)

        for (joystickIndex, joystickMapping) in preset.joysticks.enumerated() {
            // External-only bindings can fire even without a controller, so
            // we don't bail out when the slot is empty - we just skip the
            // controller-side checks for that binding.
            let state = controllerService.readControllerState(at: joystickIndex)

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

            for binding in joystickMapping.bindings {
                let isActive: Bool
                if binding.input.type == .extKey || binding.input.type == .extMouse {
                    isActive = checkExternalInput(binding.input)
                } else if let s = state {
                    isActive = checkInput(binding.input, state: s, binding: binding)
                } else {
                    // Controller binding but the slot is empty - can't fire.
                    isActive = false
                }
                let inputKey = cachedKey(for: binding)
                // bindKey is keyed by binding UUID so two distinct
                // bindings on the same physical input (e.g. one toggle,
                // one turbo, or two different macros) don't share
                // toggleStates / turboTimestamps entries. Previously
                // bindKey was "\(joystickIndex):\(inputKey)" which
                // collided when the user added a second binding on
                // the same input.
                let bindKey = "\(joystickIndex):\(binding.id.uuidString)"

                if isActive {
                    scratchActiveSet.insert(inputKey)
                }

                let wasActive = activeStates[joystickIndex]?.contains(inputKey) ?? false

                if binding.toggleMode == true {
                    // Toggle mode: press toggles on/off
                    if isActive && !wasActive {
                        let isToggledOn = toggleStates[bindKey] ?? false
                        if isToggledOn {
                            if debugEnabled { log("TOGGLE OFF: \(inputKey)", joystick: joystickIndex) }
                            fireOutputs(binding.outputs, press: false)
                            toggleStates[bindKey] = false
                        } else {
                            if debugEnabled {
                                log("TOGGLE ON: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                            }
                            fireOutputs(binding.outputs, press: true)
                            toggleStates[bindKey] = true
                            fireFeedback(for: binding, joystickIndex: joystickIndex)
                        }
                    }
                    // Keep firing continuous outputs while toggled on
                    if toggleStates[bindKey] == true, let s = state {
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                    }
                } else if binding.turboEnabled == true {
                    // Turbo mode: rapid fire while held
                    if isActive {
                        if !wasActive {
                            if debugEnabled {
                                log("TURBO START: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
                            }
                            fireFeedback(for: binding, joystickIndex: joystickIndex)
                        }
                        // Clamp turbo rate to a sane range so a zero or
                        // negative value (from a malformed preset) can't
                        // produce a +Infinity interval that disables
                        // turbo entirely. 1 Hz floor / 60 Hz ceiling.
                        let rate = max(1, min(60, binding.turboRate ?? 10))
                        let interval = 1.0 / Double(rate)
                        let lastFire = turboTimestamps[bindKey] ?? -.infinity
                        if nowMonotonic - lastFire >= interval {
                            fireOutputs(binding.outputs, press: true)
                            // Schedule release after ~40% of the interval.
                            // Capture engineGeneration so a stop() between
                            // press and release skips the release fire on
                            // a poisoned engine (avoids stuck keys when
                            // the user deactivates the preset mid-turbo).
                            let gen = engineGeneration
                            let outputs = binding.outputs
                            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 0.4) { [weak self] in
                                guard let self = self, self.engineGeneration == gen else { return }
                                self.fireOutputs(outputs, press: false)
                            }
                            turboTimestamps[bindKey] = nowMonotonic
                        }
                        if let s = state {
                            fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                        }
                    } else if wasActive {
                        log("TURBO END: \(inputKey)", joystick: joystickIndex)
                        fireOutputs(binding.outputs, press: false)
                        turboTimestamps.removeValue(forKey: bindKey)
                    }
                } else {
                    // Normal mode
                    if isActive && !wasActive {
                        StatsService.shared.recordButtonPress(inputKey: inputKey)
                        if debugEnabled {
                            log("PRESS: \(inputKey) -> \(binding.outputs.map(\.serialized))", joystick: joystickIndex)
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
                                executeMacro(steps, joystickIndex: joystickIndex, bindKey: bindKey)
                            }
                        } else if (binding.repeatCount ?? 1) > 1 {
                            fireWithRepeat(binding)
                        } else {
                            fireOutputs(binding.outputs, press: true)
                        }
                        fireFeedback(for: binding, joystickIndex: joystickIndex)
                    } else if !isActive && wasActive {
                        if debugEnabled { log("RELEASE: \(inputKey)", joystick: joystickIndex) }
                        if binding.macroSteps == nil && (binding.repeatCount ?? 1) <= 1 {
                            fireOutputs(binding.outputs, press: false)
                        }
                    } else if isActive, let s = state {
                        fireContinuousOutputs(binding.outputs, input: binding.input, state: s, binding: binding)
                    }
                }
            }

            // Copy out into activeStates (cheap Set copy) so the
            // scratch can be reused next iteration.
            activeStates[joystickIndex] = scratchActiveSet
        }

        // Flush accumulated mouse and scroll deltas as a single CGEvent.
        // Skipped while outputsPaused so the editor can stay open over an
        // active touchpad-mouse preset without the cursor flying around.
        // (Deltas themselves are zeroed at the start of every frame.)
        if !outputsPaused {
            if pendingMouseDeltaX != 0 || pendingMouseDeltaY != 0 {
                InputSimulator.shared.moveMouse(deltaX: pendingMouseDeltaX, deltaY: pendingMouseDeltaY)
                StatsService.shared.recordMouseMotion(pixels: abs(pendingMouseDeltaX) + abs(pendingMouseDeltaY))
            }
            if pendingScrollDeltaX != 0 || pendingScrollDeltaY != 0 {
                InputSimulator.shared.scrollWheel(deltaX: pendingScrollDeltaX, deltaY: pendingScrollDeltaY)
                StatsService.shared.recordScroll(ticks: Int(abs(pendingScrollDeltaX) + abs(pendingScrollDeltaY)))
            }
        }

        // Update active inputs for UI highlighting. Reuse the scratch
        // set so the union doesn't allocate a fresh container every
        // poll frame.
        scratchAllActiveSet.removeAll(keepingCapacity: true)
        for (_, states) in activeStates {
            scratchAllActiveSet.formUnion(states)
        }
        if scratchAllActiveSet != activeInputs {
            activeInputs = scratchAllActiveSet
            // Throttle the @Published mirror to 10 Hz so the highlighted
            // row in the editor doesn't trigger a full sheet re-render on
            // every poll frame. Uses the monotonic clock we already
            // captured at the top of pollControllers, no extra Date()
            // allocation.
            if nowMonotonic - activeInputsLastFlush > 0.1 {
                activeInputsLastFlush = nowMonotonic
                activeInputsPublished = scratchAllActiveSet
            }
        }

        // Drain external motion / scroll deltas now that bindings have read
        // them. Buttons and held keys stay sticky until released.
        externalMouseDX.removeAll(keepingCapacity: true)
        externalMouseDY.removeAll(keepingCapacity: true)
        externalScrollDX.removeAll(keepingCapacity: true)
        externalScrollDY.removeAll(keepingCapacity: true)
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
            switch input.axisDirection {
            case .positive:
                return value > axisThreshold
            case .negative:
                return value < -axisThreshold
            case .none:
                return abs(value) > axisThreshold
            }

        case .hat:
            guard let hat = state.hats[input.index] else { return false }
            // Inclusive (>=) comparisons so an exact-edge value of 0.5
            // counts as pressed. Many d-pads quantise to {-1, 0, +1};
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
            guard TouchpadService.shared.isFingerActive(finger),
                  let axis = input.touchpadAxis else { return false }
            // Peek without consuming so the continuous-output pass
            // later in the same poll frame still sees the delta. The
            // old code called consumeDelta here, zeroing the
            // accumulator, which broke analog touchpad-to-mouse
            // bindings (they fired once on swipe entry, then nothing).
            let value = TouchpadService.shared.peekDelta(finger: finger, axis: axis)
            switch input.axisDirection {
            case .positive: return value > axisThreshold
            case .negative: return value < -axisThreshold
            case .none:     return abs(value) > axisThreshold
            }

        case .touchpadRegion:
            // Press for as long as any finger sits inside the named region.
            guard let id = input.touchpadRegionID else { return false }
            return TouchpadService.shared.isRegionPressed(id)

        case .cursorRegion:
            // Mac-trackpad / mouse analogue of `.touchpadRegion`: press
            // while the cursor sits inside a user-defined screen rect.
            // Position is fed continuously by ExternalInputDeviceService's
            // CGEventTap as the cursor moves.
            guard let id = input.cursorRegionID else { return false }
            return CursorRegionService.shared.isRegionPressed(id)

        case .stickRegion:
            // Joystick stick analogue of `.touchpadRegion`: press
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
            // Re-pack into an axes dict for the service so the
            // existing region-matching code stays unchanged.
            var axesForService = state.axes
            axesForService[xAxisIdx] = xRaw
            axesForService[yAxisIdx] = yRaw
            return StickRegionService.shared.isRegionPressed(id, axes: axesForService)

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
            return TouchpadService.shared.consumeGesture(kind)

        case .motion:
            // Motion is treated as a half-axis: pick the channel and
            // direction the binding asked for, threshold on a small dead
            // zone so resting drift doesn't fire the binding.
            guard let channel = input.motionChannel,
                  let raw = state.motion[channel] else { return false }
            let value = (binding?.invertAxis == true) ? -raw : raw
            switch input.axisDirection {
            case .positive: return value > axisThreshold
            case .negative: return value < -axisThreshold
            case .none:     return abs(value) > axisThreshold
            }

        case .extKey, .extMouse:
            // Routed through `checkExternalInput` instead; this branch is
            // only reachable from legacy code paths that don't expect
            // external types.
            return checkExternalInput(input)
        }
    }

    // MARK: - Output Firing

    private func fireOutputs(_ outputs: [OutputAction], press: Bool) {
        if outputsPaused { return }
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
        for output in outputs {
            switch output.type {
            case .key:
                if let code = output.keyCode {
                    if press {
                        InputSimulator.shared.keyDown(code)
                    } else {
                        InputSimulator.shared.keyUp(code)
                    }
                }

            case .mouseButton:
                if let btn = output.mouseButtonIndex {
                    if press {
                        InputSimulator.shared.mouseButtonDown(btn)
                    } else {
                        InputSimulator.shared.mouseButtonUp(btn)
                    }
                }

            case .mouseWheelStep:
                if press, let axis = output.mouseAxis, let dir = output.mouseDirection {
                    InputSimulator.shared.scrollWheelStep(axis: axis, direction: dir)
                }

            case .mouseMotion, .mouseWheel:
                break

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
                let cc = output.midiCCNumber ?? 1
                let ch = output.midiChannel ?? 1
                // Buttons fire the configured value on press, 0 on release.
                // Axes are handled by fireContinuousOutputs for smooth values.
                let value = press ? (output.midiCCValue ?? 127) : 0
                MIDIService.shared.sendCC(controller: cc, value: value, channel: ch)

            case .midiPitchBend:
                let ch = output.midiChannel ?? 1
                // Buttons snap to full bend on press, recenter on release.
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
    private func executeMacro(_ steps: [MacroStep], joystickIndex: Int, bindKey: String) {
        StatsService.shared.recordMacroExecution()
        log("MACRO: executing \(steps.count) steps", joystick: joystickIndex)
        let scheduledGen = engineGeneration
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for step in steps {
                guard self != nil else { return }
                // Pre-step delay (clamped to 30s).
                if step.delayMs > 0 {
                    let secs = min(Double(step.delayMs) / 1000.0, 30.0)
                    Thread.sleep(forTimeInterval: secs)
                }
                // Press - guard generation on main where it's safe to read.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.engineGeneration == scheduledGen else { return }
                    self.fireOutputs([step.action], press: true)
                }
                // Hold (clamped to 30s).
                if step.holdMs > 0 {
                    let secs = min(Double(step.holdMs) / 1000.0, 30.0)
                    Thread.sleep(forTimeInterval: secs)
                }
                // Release - same guard. CRITICAL: also release the
                // step on engine teardown so a macro mid-hold that
                // gets shut down by stop() doesn't leave a synthesized
                // key permanently down. fireOutputs(press: false) is
                // safe to call even when the engine has moved on.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.engineGeneration == scheduledGen {
                        self.fireOutputs([step.action], press: false)
                    } else {
                        // Generation changed mid-hold (preset switch
                        // or stop). Still release the step's output
                        // so the synthesized key doesn't stick.
                        InputSimulator.shared.releaseAll()
                    }
                }
            }
            // Whole chain done; clear the in-flight flag so the next
            // press can fire a fresh macro execution.
            DispatchQueue.main.async { [weak self] in
                self?.macrosInFlight.remove(bindKey)
            }
        }
    }

    /// Execute outputs with repeat count.
    ///
    /// Repeat count is clamped to 10 000 and delay to 30 s to bound the
    /// worst-case from an adversarial / malformed preset. Each fire
    /// hop checks `engineGeneration` against the value captured at
    /// schedule time so an active repeat won't leak past stop().
    private func fireWithRepeat(_ binding: BindingModel) {
        let rawCount = binding.repeatCount ?? 1
        let count = max(1, min(10_000, rawCount))
        let rawDelayMs = binding.repeatDelayMs ?? 100
        let delaySecs = min(Double(rawDelayMs) / 1000.0, 30.0)

        if count <= 1 {
            fireOutputs(binding.outputs, press: true)
            return
        }

        let scheduledGen = engineGeneration
        let outputs = binding.outputs
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for i in 0..<count {
                guard self != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.engineGeneration == scheduledGen else { return }
                    self.fireOutputs(outputs, press: true)
                }
                Thread.sleep(forTimeInterval: 0.05)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.engineGeneration == scheduledGen else { return }
                    self.fireOutputs(outputs, press: false)
                }
                if i < count - 1 {
                    Thread.sleep(forTimeInterval: delaySecs)
                }
            }
        }
    }

    private func fireContinuousOutputs(_ outputs: [OutputAction], input: InputEvent, state: ControllerState, binding: BindingModel? = nil) {
        if outputsPaused { return }
        for output in outputs {
            switch output.type {
            case .mouseMotion:
                guard let axis = output.mouseAxis, let dir = output.mouseDirection else { continue }
                let speed = output.speed ?? 6

                // Variable sensitivity defaults to true for axis input (gives natural feel).
                // When false, output fires at full speed once the axis crosses the deadzone.
                let useVariable = binding?.variableSensitivity ?? (input.type == .axis || input.type == .touchpad || input.type == .motion)

                var magnitude: Float = 1.0
                var signedMagnitude: Float = 1.0   // for touchpad / motion: sign indicates direction of motion
                if useVariable, input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
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
                    var delta = TouchpadService.shared.consumeDelta(finger: finger, axis: tpAxis)
                    if binding?.invertAxis == true { delta = -delta }
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

                // Motion (gyro / accel) feeds the analog mouse path the same
                // way touchpad delta does. A positive gyro-Y while bound to
                // mouse-X+ moves the cursor right; the binding's invertAxis
                // flag flips the polarity.
                if useVariable, input.type == .motion,
                   let channel = input.motionChannel,
                   var motionValue = state.motion[channel] {
                    if binding?.invertAxis == true { motionValue = -motionValue }
                    // Filter by half-axis like we do for touchpad.
                    switch input.axisDirection {
                    case .positive: if motionValue < 0 { motionValue = 0 }
                    case .negative: if motionValue > 0 { motionValue = 0 }
                    case .none: break
                    }
                    // Gyro rotation rate is roughly radians/sec; tilt of a
                    // controller during normal gameplay produces values up
                    // to ~5 rad/s. Apply a moderate gain so a wrist twist
                    // gives a useful cursor delta.
                    let gain: Float = 8.0
                    signedMagnitude = motionValue * gain
                    magnitude = abs(signedMagnitude)
                }

                let scaledSpeed: Int
                if input.type == .touchpad || input.type == .motion {
                    // signedMagnitude already encodes direction + speed;
                    // mouseDirection picks which CGEvent axis it adds to.
                    // Guard against NaN/Inf: an uncalibrated DualSense
                    // can briefly publish NaN motion samples right
                    // after connect, and `Int(.nan)` is a hard crash.
                    let raw = abs(signedMagnitude) * Float(speed) / 6.0
                    scaledSpeed = raw.isFinite ? Int(raw) : 0
                } else {
                    let raw = Float(speed) * magnitude
                    scaledSpeed = raw.isFinite ? Int(raw) : 0
                }
                // Accumulate into pendingMouseDelta. The poll loop flushes
                // the total in a single CGEvent at the end of the frame so
                // diagonal motion combines naturally.
                switch (axis, dir) {
                case (.horizontal, .positive): pendingMouseDeltaX += scaledSpeed
                case (.horizontal, .negative): pendingMouseDeltaX -= scaledSpeed
                case (.vertical, .positive): pendingMouseDeltaY += scaledSpeed
                case (.vertical, .negative): pendingMouseDeltaY -= scaledSpeed
                }

            case .mouseWheel:
                guard let axis = output.mouseAxis, let dir = output.mouseDirection else { continue }
                let speed = output.speed ?? 6

                let useVariable = binding?.variableSensitivity ?? (input.type == .axis)

                var magnitude: Float = 1.0
                if useVariable, input.type == .axis, var axisValue = state.axes[input.index] {
                    if binding?.invertAxis == true { axisValue = -axisValue }
                    let rawMag = min(abs(axisValue), 1.0)
                    magnitude = remapMagnitude(rawMag, binding: binding)
                    if let curve = binding?.sensitivityCurve {
                        magnitude = abs(curve.apply(magnitude))
                    }
                }

                // Same NaN guard as the mouse-motion path above.
                let rawScroll = Float(speed) * magnitude
                let scaledSpeed = rawScroll.isFinite ? Int32(rawScroll) : 0
                switch (axis, dir) {
                case (.horizontal, .positive): pendingScrollDeltaX += scaledSpeed
                case (.horizontal, .negative): pendingScrollDeltaX -= scaledSpeed
                case (.vertical, .positive): pendingScrollDeltaY += scaledSpeed
                case (.vertical, .negative): pendingScrollDeltaY -= scaledSpeed
                }

            case .midiCC:
                // Continuous axis driving a CC. Map the axis's full range to
                // 0..127. For positive-only inputs (triggers, axis "positive"
                // direction) we map 0..1 to 0..127. For full-range axes we
                // map -1..1 to 0..127.
                guard input.type == .axis, var axisValue = state.axes[input.index] else { continue }
                if binding?.invertAxis == true { axisValue = -axisValue }

                let ccValue: Int
                if input.axisDirection == .positive {
                    var mag = max(0, min(1, axisValue))
                    if let curve = binding?.sensitivityCurve { mag = abs(curve.apply(mag)) }
                    ccValue = Int(mag * 127)
                } else if input.axisDirection == .negative {
                    var mag = max(0, min(1, -axisValue))
                    if let curve = binding?.sensitivityCurve { mag = abs(curve.apply(mag)) }
                    ccValue = Int(mag * 127)
                } else {
                    // Full-range axis: -1..1 maps to 0..127
                    let normalized = (axisValue + 1) / 2
                    ccValue = Int(max(0, min(1, normalized)) * 127)
                }
                let cc = output.midiCCNumber ?? 1
                let ch = output.midiChannel ?? 1
                MIDIService.shared.sendCC(controller: cc, value: ccValue, channel: ch)

            case .midiPitchBend:
                // Pitch bend is signed and centered at 8192. -1..1 maps to 0..16383.
                guard input.type == .axis, var axisValue = state.axes[input.index] else { continue }
                if binding?.invertAxis == true { axisValue = -axisValue }
                var v: Float
                if input.axisDirection == .positive {
                    v = max(0, min(1, axisValue))
                } else if input.axisDirection == .negative {
                    v = -max(0, min(1, -axisValue))
                } else {
                    v = max(-1, min(1, axisValue))
                }
                if let curve = binding?.sensitivityCurve {
                    let mag = curve.apply(abs(v))
                    v = v >= 0 ? mag : -mag
                }
                let pbValue = Int((v + 1) / 2 * 16383)
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
        if outputsPaused { return }
        if binding.hapticEnabled == true,
           joystickIndex < controllerService.connectedControllers.count {
            let controller = controllerService.connectedControllers[joystickIndex]
            let intensity = binding.hapticIntensity ?? 0.6
            FeedbackService.shared.vibrate(controller: controller, intensity: intensity)
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
