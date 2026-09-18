import Foundation
import QuartzCore
import GameController
import Combine
import AppKit

/// Readable info about a connected controller.
///
/// Equatable so the 30 s details refresh can skip re-assigning the
/// @Published `controllerDetails` dict when nothing actually changed.
/// `connectedAt` is intentionally excluded from the comparison - it's
/// always slightly different per refresh and we don't want that to
/// invalidate equality and trigger a view storm.
struct ControllerInfo: Equatable {
    var name: String
    var productCategory: String
    var hasExtendedGamepad: Bool
    var hasLight: Bool
    var hasBattery: Bool
    var batteryLevel: Float?
    var batteryState: String?
    var buttonCount: Int
    var axisCount: Int
    var supportsMotion: Bool
    var connectedAt: Date = Date()
    var hasTouchpad: Bool = false
    var hasMicroGamepad: Bool = false
    var hasAdaptiveTriggers: Bool = false
    var physicalButtonNames: [String] = []
    var brand: ControllerBrand = .unknown

    static func == (lhs: ControllerInfo, rhs: ControllerInfo) -> Bool {
        return lhs.name == rhs.name
            && lhs.productCategory == rhs.productCategory
            && lhs.hasExtendedGamepad == rhs.hasExtendedGamepad
            && lhs.hasLight == rhs.hasLight
            && lhs.hasBattery == rhs.hasBattery
            && lhs.batteryLevel == rhs.batteryLevel
            && lhs.batteryState == rhs.batteryState
            && lhs.buttonCount == rhs.buttonCount
            && lhs.axisCount == rhs.axisCount
            && lhs.supportsMotion == rhs.supportsMotion
            && lhs.hasTouchpad == rhs.hasTouchpad
            && lhs.hasMicroGamepad == rhs.hasMicroGamepad
            && lhs.hasAdaptiveTriggers == rhs.hasAdaptiveTriggers
            && lhs.physicalButtonNames == rhs.physicalButtonNames
            && lhs.brand == rhs.brand
    }
}

/// Represents the current state of a connected controller
struct ControllerState {
    var buttons: [Int: Float] = [:]   // button index -> value (0.0 or 1.0)
    var axes: [Int: Float] = [:]      // axis index -> value (-1.0 to 1.0)
    var hats: [Int: (x: Float, y: Float)] = [:] // hat index -> (x, y) direction
    /// Motion-sensor channels - populated when the controller exposes a
    /// non-nil `motion` property (DualSense, DualShock 4, Switch Pro,
    /// Joy-Con). nil otherwise. Channel-keyed Float so MappingEngine can
    /// treat them like axis values.
    var motion: [MotionChannel: Float] = [:]
    /// Radians the controller actually turned around each gyro axis since
    /// the previous poll, summed from every sensor sample (drift removed).
    /// The pointer path uses this, not the rate, so a movement and its
    /// exact reverse cancel to zero no matter how fast either was.
    var motionAngle: [MotionChannel: Float] = [:]
    /// Extra radians this poll from the accelerometer anchor on pitch: the
    /// amount the fused estimate moved beyond what the gyro reported. The
    /// pointer path adds it untouched (no tightening, no gate), so the
    /// pointer always ends where the controller's real angle says.
    var motionCorrection: [MotionChannel: Float] = [:]
    /// Absolute tilt in radians, fused gyro + accelerometer, keyed by the
    /// gyro channel that rotates about that axis: `.gyroX` is pitch (nose
    /// up positive), `.gyroY` is roll (right side down positive). The
    /// pointing path positions the pointer from these.
    var motionAbsolute: [MotionChannel: Float] = [:]

    /// Pre-size the backing dictionaries so the per-frame population in the
    /// 120 Hz poll loop (and the 30 Hz raw-input refresh) does not repeatedly
    /// rehash as it inserts. A controller reports up to ~21 buttons and 6
    /// axes; reserving once per fresh state removes that steady-state growth
    /// churn on the main actor without changing any read logic or output.
    init() {
        buttons.reserveCapacity(24)
        axes.reserveCapacity(8)
        hats.reserveCapacity(4)
        motion.reserveCapacity(8)
    }
}

/// One observed press from a physical input profile button.
struct PhysicalPressLog: Identifiable {
    let id = UUID()
    let slot: Int
    let name: String
    let mappedIndex: Int?
    let at: Date
}

/// Diagnostic log of recent physical button presses, shown only in the
/// Settings "Live press log". Kept OUT of GameControllerService so its
/// high-frequency, per-press updates don't invalidate the root ContentView,
/// which observes the controller service.
@MainActor
final class PhysicalPressLogStore: ObservableObject {
    static let shared = PhysicalPressLogStore()
    private init() {}

    @Published var recent: [PhysicalPressLog] = []

    func log(slot: Int, name: String, mappedIndex: Int?) {
        recent.insert(PhysicalPressLog(slot: slot, name: name, mappedIndex: mappedIndex, at: Date()), at: 0)
        if recent.count > 30 {
            recent.removeLast(recent.count - 30)
        }
    }
}

/// Holds an NSProcessInfo activity while anything needs full-rate timers
/// in the background, and drops it the moment nothing does.
@MainActor
final class AppActivity {
    static let shared = AppActivity()
    private var reasons: Set<String> = []
    private var token: NSObjectProtocol?
    private init() {}

    func retain(_ reason: String) {
        reasons.insert(reason)
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keeping controller input and light timers at full rate")
    }

    func release(_ reason: String) {
        reasons.remove(reason)
        guard reasons.isEmpty, let t = token else { return }
        ProcessInfo.processInfo.endActivity(t)
        token = nil
    }

    /// The engine announces itself through notifications; follow them.
    func observeEngine() {
        NotificationCenter.default.addObserver(forName: MappingEngine.didStartNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retain("engine") }
        }
        NotificationCenter.default.addObserver(forName: MappingEngine.didStopNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.release("engine") }
        }
    }
}

/// The two live-input sets the editor lights its rows from, kept away
/// from the service and engine objects that the whole window observes.
/// Publishing them from those objects re-rendered the root view, the
/// sidebar and the log on every input edge: with frosted layers that
/// meant the main thread waiting on the WindowServer while the engine's
/// own poll timer, which shares that thread, fired late. That was the
/// touchpad lag whenever the visualizer was on screen. Only the editor's
/// row list observes this store.
@MainActor
final class LiveInputStore: ObservableObject {
    static let shared = LiveInputStore()
    /// Raw controller activity: buttons, axes, hats, zones and gestures.
    @Published var raw: Set<String> = []
    /// What the running preset considers active, 10 Hz at most.
    @Published var active: Set<String> = []
    private init() {}
}

/// Manages game controller detection and input reading
@MainActor
class GameControllerService: ObservableObject {
    @Published var connectedControllers: [GCController] = []
    @Published var controllerNames: [Int: String] = [:]
    @Published var controllerDetails: [Int: ControllerInfo] = [:]
    // Not @Published: no view observes these (LED state is driven to hardware
    // and the RGB/brightness UI reads rgbCycleActive/lightPresets instead), so
    // publishing fired the whole service's objectWillChange on every 10 Hz RGB
    // tick for zero UI benefit. Plain vars: identical internal reads/writes.
    var lightColors: [Int: (r: Float, g: Float, b: Float)] = [:]
    var lightBrightness: [Int: UInt8] = [:] // 0=off, 1=dim, 2=bright
    // NOTE: there used to be a `@Published var lastInput` here that every
    // scan handler wrote on every input event. Nothing read it, but each
    // write fired objectWillChange on this service at the controller's
    // report rate (250+ Hz on Bluetooth), forcing a full re-layout of every
    // observing view. Held sticks pinned the main thread at 90%+ CPU.
    @Published var isScanning: Bool = false
    /// Serialized input event strings (e.g. "btn 5", "axi 0 +") that are
    /// currently pressed / deflected across *any* connected controller.
    /// Refreshed at 10 Hz independent of the mapping engine, so the editor's
    /// binding row highlight works even when no preset is running.
    /// Not published here on purpose: see LiveInputStore. The store gets
    /// the same value on every change.
    var rawActiveInputs: Set<String> = [] {
        didSet { LiveInputStore.shared.raw = rawActiveInputs }
    }

    /// When true, the Quick Tour has injected a synthetic DualSense
    /// Edge entry into `controllerDetails[0]` so the visualizer can
    /// render all its widgets even with no real controller connected.
    /// The tour clears this on tear-down. Backing storage for the
    /// real entry (if any) is preserved.
    @Published private(set) var tutorialFakeControllerActive: Bool = false
    private var preTutorialControllerDetails: ControllerInfo?

    /// Install a synthetic DualSense Edge entry into slot 0 so the
    /// Quick Tour can light up every visualizer widget regardless of
    /// what hardware the user has plugged in. Reversible via
    /// `disableTutorialFakeController()`.
    func enableTutorialFakeController() {
        preTutorialControllerDetails = controllerDetails[0]
        let info = ControllerInfo(
            name: "DualSense Edge Wireless Controller (Tutorial)",
            productCategory: "DualSense Edge",
            hasExtendedGamepad: true,
            hasLight: true,
            hasBattery: true,
            batteryLevel: 1.0,
            batteryState: "charging",
            buttonCount: 18,
            axisCount: 6,
            supportsMotion: true,
            hasTouchpad: true,
            hasMicroGamepad: false,
            hasAdaptiveTriggers: true,
            physicalButtonNames: ["A", "B", "X", "Y", "LB", "RB",
                                  "LT", "RT", "Share", "Menu", "Home",
                                  "L3", "R3", "Touchpad", "Mute",
                                  "Left Paddle", "Right Paddle"],
            brand: .dualSense
        )
        controllerDetails[0] = info
        tutorialFakeControllerActive = true
        // Set a flag so a force-quit during the tour doesn't leave the
        // synthetic controller in place on next launch. We check this
        // in init() and immediately undo if found.
        UserDefaults.standard.set(true, forKey: Self.tutorialFakeFlagKey)
    }

    /// Remove the synthetic Quick Tour controller and restore whatever
    /// real entry was there before (or nothing).
    func disableTutorialFakeController() {
        if let real = preTutorialControllerDetails {
            controllerDetails[0] = real
        } else {
            controllerDetails.removeValue(forKey: 0)
        }
        preTutorialControllerDetails = nil
        tutorialFakeControllerActive = false
        UserDefaults.standard.removeObject(forKey: Self.tutorialFakeFlagKey)
    }

    /// UserDefaults key for the "synthetic tutorial controller is
    /// currently injected" flag. Persists across launches so a force-
    /// quit during the tour can be detected and cleaned up.
    private static let tutorialFakeFlagKey = "InputConfig.tutorialFakeActive"

    /// Called from init() to clear any lingering synthetic controller
    /// left behind by a force-quit during the previous tour session.
    /// Safe to call when no synthetic was active.
    private func clearStaleTutorialFakeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.tutorialFakeFlagKey) else { return }
        // The synthetic only ever lives at slot 0. Anything that was
        // there is gone now anyway - real controllers re-register
        // through the connect notification.
        controllerDetails.removeValue(forKey: 0)
        UserDefaults.standard.removeObject(forKey: Self.tutorialFakeFlagKey)
        NSLog("[GameControllerService] Cleared stale tutorial fake controller from previous session")
    }

    /// True while the DEBUG marketing capture fakes are installed. Always
    /// false in Release, so the shipping sidebar is unaffected.
    var debugMarketingFakeActive: Bool {
        #if DEBUG
        return marketingFakeActive
        #else
        return false
        #endif
    }

    #if DEBUG
    @Published private(set) var marketingFakeActive = false
    /// Marketing capture: hold a trigger and two buttons on the synthetic
    /// pad (inputconfig.debug.fakepress toggles it). DEBUG only.
    var marketingFakePress = false
    /// DEBUG / marketing-capture only: inject two clean-named synthetic
    /// controllers (a DualSense Edge in slot 0, a PlayStation Access Controller
    /// in slot 1) so App Store screenshots show a populated sidebar and a
    /// fully-drawn visualizer with no hardware attached. Unlike the Quick Tour
    /// fake there is no "(Tutorial)" suffix. `refreshControllers()` is guarded
    /// to leave these in place. Driven by DebugMarketing.fakeController (which
    /// the `inputconfig.debug.fakecontroller` notification toggles); never
    /// compiled into a Release build.
    func setMarketingFakeControllers(_ on: Bool) {
        guard on != marketingFakeActive else { return }
        if !on {
            controllerDetails.removeValue(forKey: 0)
            controllerDetails.removeValue(forKey: 1)
            controllerNames.removeValue(forKey: 0)
            controllerNames.removeValue(forKey: 1)
            marketingFakeActive = false
            return
        }
        marketingFakeActive = true
        controllerNames[0] = "DualSense Edge Wireless Controller"
        controllerNames[1] = "Access Controller"
        controllerDetails[0] = ControllerInfo(
            name: "DualSense Edge Wireless Controller",
            productCategory: "DualSense Edge",
            hasExtendedGamepad: true, hasLight: true, hasBattery: true,
            batteryLevel: 1.0, batteryState: "charging",
            buttonCount: 18, axisCount: 6, supportsMotion: true,
            hasTouchpad: true, hasMicroGamepad: false, hasAdaptiveTriggers: true,
            physicalButtonNames: ["A", "B", "X", "Y", "LB", "RB", "LT", "RT",
                                  "Share", "Menu", "Home", "L3", "R3", "Touchpad",
                                  "Mute", "Left Paddle", "Right Paddle"],
            brand: .dualSense)
        controllerDetails[1] = ControllerInfo(
            name: "Access Controller",
            productCategory: "Access Controller",
            hasExtendedGamepad: true, hasLight: false, hasBattery: true,
            batteryLevel: 0.95, batteryState: "discharging",
            buttonCount: 8, axisCount: 2, supportsMotion: false,
            hasTouchpad: false, hasMicroGamepad: false, hasAdaptiveTriggers: false,
            physicalButtonNames: ["1", "2", "3", "4", "5", "6", "7", "8"],
            brand: .dualSense)
    }
    #endif

    /// Per-slot snapshot of the latest `ControllerState`. Updated at the
    /// same 30 Hz cadence as `rawActiveInputs`. Drives the live virtual
    /// controller visualizer.
    ///
    /// **Intentionally NOT `@Published`.** `ControllerState` doesn't conform
    /// to `Equatable` (the hat tuples can't auto-derive it), so this dict is
    /// reassigned every 30 Hz tick whether or not anything actually changed.
    /// Publishing it triggered every `@EnvironmentObject controllerService`
    /// observer to re-render 30x/sec, which made the editor and other busy
    /// views laggy. The visualizer reads this dictionary via `TimelineView`
    /// at its own cadence, so observation isn't necessary.
    var currentStates: [Int: ControllerState] = [:]

    /// Rolling log of every physical-profile button name that fired on each
    /// connected controller. Drives the Settings > Controllers diagnostic
    /// so the user can see whether a press registers and under what name -
    /// useful when a controller's button (e.g. DualSense Edge paddle) has
    /// a name our mapping table doesn't recognize. Capped at 30 entries.
    // The live physical-press diagnostic log lives in PhysicalPressLogStore
    // (defined just above this class), NOT here. It updates on every button
    // press, and on this @Published-heavy service that invalidated the root
    // ContentView (which observes the service) on every press. Only the
    // Settings "Live press log" observes the store now.

    /// Cached mapping of physical profile button name -> button index for each controller slot.
    /// Built once on connection, used every poll frame to avoid re-sorting/re-matching at 120Hz.
    private var cachedExtraButtons: [Int: [(GCControllerButtonInput, Int)]] = [:]

    /// Live snapshot of every "extra" button (PS, mute, paddles, FN,
    /// share, etc.) registered for a controller slot. Each entry pairs
    /// a human-readable label with the current pressed value. The
    /// visualizer renders these as chips so users can see at a glance
    /// what their controller is reporting.
    struct ExtraButton: Identifiable, Equatable {
        /// Stable identity derived from the button's logical index.
        /// Previously this was a fresh UUID per snapshot, which made
        /// every call to `extraButtonsSnapshot` return arrays that
        /// SwiftUI considered "different" - downstream views received
        /// new `extraButtons` parameters every 30 Hz poll tick and
        /// interfered with the binding row's highlight animation.
        var id: Int { index }
        let label: String
        let index: Int
        let pressed: Bool
    }

    func extraButtonsSnapshot(for slot: Int) -> [ExtraButton] {
        // Native GCController path: KVC-discovered buttons (paddles,
        // mute, share, FN) live in cachedExtraButtons.
        if let cached = cachedExtraButtons[slot] {
            var out = cached.map { (button, index) in
                ExtraButton(label: Self.labelForExtraButton(index: index, button: button),
                            index: index,
                            pressed: button.value > 0.5)
            }
            // Augment with DualSense Edge supplemental buttons (paddle/
            // FN/mute) when the slot's controller is a DualSense. We
            // read those bits via raw HID in DualSenseSupplementService
            // because Apple's GameController framework doesn't expose
            // them. The merge is keyed by index so a name from the
            // native list (if any) takes priority over our static names.
            if slot < connectedControllers.count {
                let c = connectedControllers[slot]
                let nameBlob = ((c.vendorName ?? "") + " " + c.productCategory).lowercased()
                let isDualSense = nameBlob.contains("dualsense")
                let isEdge = nameBlob.contains("edge")
                if isDualSense {
                    let supplement = DualSenseSupplementService.shared.anySupplementalButtons()
                    let existingIndices = Set(out.map(\.index))
                    // Every DualSense has the mute button. Only the Edge has
                    // paddles and FN buttons; listing them on a plain
                    // DualSense made the automatic layout offer controls the
                    // pad does not have.
                    var supplementNames: [Int: String] = [15: "Microphone / Mute"]
                    if isEdge {
                        supplementNames[16] = "Left Paddle"
                        supplementNames[17] = "Right Paddle"
                        supplementNames[20] = "FN 1 (Left Function)"
                        supplementNames[21] = "FN 2 (Right Function)"
                    }
                    for (idx, name) in supplementNames where !existingIndices.contains(idx) {
                        let pressed = (supplement[idx] ?? 0) > 0.5
                        out.append(ExtraButton(label: name, index: idx, pressed: pressed))
                    }
                }
            }
            return out.sorted { $0.index < $1.index }
        }
        // Raw HID path: anything in state.buttons beyond the standard
        // 0-12 slots (face/shoulder/trigger/menu/stick-click) is an
        // "extra" button. Most gamepads have none; fight sticks /
        // arcade pads / custom controllers can have many.
        if let gamepad = rawHIDGamepadSlots[slot] {
            let state = gamepad.state
            let names = gamepad.profile?.physicalButtonNames ?? []
            let extraKeys = state.buttons.keys.filter { $0 > 12 }.sorted()
            return extraKeys.map { idx in
                let label = idx < names.count ? names[idx] : "Button \(idx)"
                return ExtraButton(label: label,
                                   index: idx,
                                   pressed: (state.buttons[idx] ?? 0) > 0.5)
            }
        }
        return []
    }

    /// Same idea for axes: anything past axis 5 (which is the standard
    /// RT analog) is an extra axis the visualizer should surface.
    /// Returns (index, label, value) tuples sorted by index. Currently
    /// only relevant for raw HID gamepads since GameController
    /// framework only exposes 6 axes.
    struct ExtraAxis: Identifiable, Equatable {
        /// Same stable-id rationale as ExtraButton above - avoids
        /// re-rendering downstream views on every snapshot tick.
        var id: Int { index }
        let label: String
        let index: Int
        let value: Float
    }

    func extraAxesSnapshot(for slot: Int) -> [ExtraAxis] {
        if let extras = cachedExtraAxes[slot], !extras.isEmpty {
            return extras.map { axis, index, name in
                ExtraAxis(label: name, index: index, value: axis.value)
            }
        }
        if let gamepad = rawHIDGamepadSlots[slot] {
            let state = gamepad.state
            let extraKeys = state.axes.keys.filter { $0 > 5 }.sorted()
            return extraKeys.map { idx in
                ExtraAxis(label: "Axis \(idx)", index: idx,
                          value: state.axes[idx] ?? 0)
            }
        }
        return []
    }

    /// Friendly name to show on each extra-button chip. Prefers the
    /// runtime's localizedName, falls back to a static map by index.
    private static func labelForExtraButton(index: Int, button: GCControllerButtonInput) -> String {
        if let localized = button.localizedName, !localized.isEmpty {
            return localized
        }
        switch index {
        case 13: return "Touchpad"
        case 14: return "Share"
        case 15: return "Microphone"
        case 16: return "Left Paddle"
        case 17: return "Right Paddle"
        case 18: return "Paddle 3"
        case 19: return "Paddle 4"
        case 20: return "FN1"
        case 21: return "FN2"
        default: return "Button \(index)"
        }
    }

    /// Slot index assigned to a connected Steam Controller. nil when no
    /// Steam Controller is currently reporting input. Always sits just past
    /// the last real MFi controller so presets keep their numbering.
    @Published var steamControllerSlot: Int?

    /// Slot indices assigned to raw HID gamepads (8BitDo Ultimate 2C in
    /// XInput mode, Xbox 360 wired, Logitech F310/F710, generic XInput
    /// pads, DualShock 3 over USB, etc.). Each entry maps a controller
    /// slot index → `RawHIDGamepad`. Slots are allocated after Steam.
    /// See `syncRawHIDGamepadSlots()`.
    @Published var rawHIDGamepadSlots: [Int: RawHIDGamepad] = [:]

    private var pollTimer: Timer?
    private var detailsTimer: Timer?
    private var steamWatchTimer: Timer?
    private var rawHIDWatchTimer: Timer?
    private var rawActivePollTimer: Timer?
    private var scanCallback: ((InputEvent) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Apple normally suppresses the Home / PS button event when an app
        // isn't actively claiming the controller. Setting this flag lets us
        // receive Home and other "background" events regardless of whether
        // the window has key focus.
        GCController.shouldMonitorBackgroundEvents = true

        // App Nap is held off only while there is a reason: a preset
        // running, or a light colour being held. Both need their timers at
        // full rate in the background. Asserting it for the whole process
        // lifetime, as before, kept the app out of App Nap with no
        // controller, no preset and no window.
        AppActivity.shared.observeEngine()

        setupControllerNotifications()
        refreshControllers()
        startDetailsPolling()
        // Spin up the Steam Controller helper at launch so the device is
        // detected immediately on plug-in. The helper does nothing until a
        // physical Steam Controller appears, then disables lizard mode and
        // starts streaming raw input reports. Re-running detection at 2 Hz
        // updates the virtual slot's ControllerInfo as the helper connects.
        startRawActiveInputsPolling()

        // Everything below is a bus walk, a subprocess, or a system
        // client, and none of it is needed for the first frame. It ran
        // synchronously inside this init, which runs inside the app's
        // state construction before the window exists, so launch waited
        // on an IOKit enumeration, a CoreMIDI client, a fork and exec and
        // three HID opens. Deferred one turn, so the window is up first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.startBusServices() }
        }

        // If a previous run force-quit during the Quick Tour, the
        // synthetic DualSense Edge entry could still be sitting at
        // slot 0 in memory we just initialized. Clean it up before
        // any UI binds to controllerDetails.
        clearStaleTutorialFakeIfNeeded()
    }

    /// The services that talk to the bus and the system, started after
    /// the first frame. See init.
    private func startBusServices() {
        // Spin up the Steam Controller helper so the device is detected
        // immediately on plug-in. The helper does nothing until a physical
        // Steam Controller appears, then disables lizard mode and starts
        // streaming raw input reports. Re-running detection at 2 Hz
        // updates the virtual slot's ControllerInfo as the helper connects.
        SteamControllerService.shared.retain()
        startSteamControllerWatch()

        // Boot the raw HID gamepad layer. Covers controllers that
        // Apple's GameController framework doesn't see (8BitDo Ultimate
        // 2C in XInput mode, Xbox 360 wired pads, Logitech F310/F710,
        // DualShock 3, generic XInput controllers).
        RawHIDGamepadService.shared.start()
        startRawHIDGamepadWatch()
        startAccessoryWatch()
        // Everything else on the bus, for the InputConfig ▸ Devices menu.
        HIDDeviceRegistry.shared.start()

        // DualSense / DualSense Edge supplement. Apple's framework
        // surfaces the standard DualSense buttons but NOT the Edge's
        // exclusive ones (left/right paddle, FN1/FN2, mute). We open
        // the device a second time in non-seize mode and parse those
        // bits out of the raw report, then merge them into the
        // matching slot's ControllerState.
        DualSenseSupplementService.shared.start()

        // MIDI input. Opens one CoreMIDI client and connects to every
        // source, so a MIDI keyboard / pad controller is bindable the
        // same way a gamepad is. Started for the session so the binding
        // editor can list devices and Scan can capture a key press
        // without the user first activating a MIDI preset.
        MIDIInputService.shared.start()

        // Open the in-process LED writer so focus-change re-asserts and
        // the RGB cycle can write instantly, without spawning the helper
        // subprocess. It's re-enumerated on each controller
        // connect/disconnect via refreshControllers().
        InProcessLightWriter.shared.open()
    }

    deinit {
        // GameController + connect/disconnect observers are registered
        // against the singleton's lifetime. The service almost always
        // outlives the app process, but adding a clean teardown makes
        // the type safe to recreate in tests and stops the leak
        // analyzer flagging it. Timer cleanup is deliberately omitted:
        // Swift 6 strict-concurrency forbids touching @MainActor /
        // non-Sendable state from a nonisolated deinit, and Timer
        // properties on a main-actor class fall into that category.
        // The Timers retain self, so deinit only ever runs once the
        // run loop has already dropped them - explicit invalidate
        // would be a no-op at that point anyway.
        NotificationCenter.default.removeObserver(self)
    }

    /// Periodically refresh battery level and other dynamic details.
    /// Only re-publishes a slot's `ControllerInfo` when it actually
    /// changed - the equality check excludes the `connectedAt`
    /// timestamp so an unchanged battery reading doesn't kick every
    /// observer into a re-render every 30 seconds.
    private func startDetailsPolling() {
        detailsTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                for (index, controller) in self.connectedControllers.enumerated() {
                    let next = self.buildControllerInfo(controller)
                    if self.controllerDetails[index] != next {
                        self.controllerDetails[index] = next
                    }
                }
            }
        }
    }

    // MARK: - Controller Discovery

    private var pendingRefresh: DispatchWorkItem?

    /// A Bluetooth reconnect can deliver "connected" for the new object
    /// before "disconnected" for the old one. Rebuilding on every
    /// notification listed both, which is the duplicate DualSense people
    /// saw. One trailing rebuild per burst collapses the pair.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshControllers() }
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func setupControllerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil, queue: .main
        ) { [weak self] note in
            // Extract Sendable values before crossing the actor boundary so
            // Swift 6's strict concurrency doesn't flag the Notification.
            let name = (note.object as? GCController)?.vendorName ?? "Controller"
            Task { @MainActor in
                StatsService.shared.controllerConnected(name: name)
                self?.scheduleRefresh()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil, queue: .main
        ) { [weak self] note in
            let gone = note.object as? GCController
            let name = gone?.vendorName ?? "Controller"
            // Identity only crosses to the main actor: the object itself
            // is not needed there, just which one it was.
            let goneID = gone.map { ObjectIdentifier($0) }
            Task { @MainActor in
                guard let self = self else { return }
                let stillConnected = !GCController.controllers().isEmpty
                StatsService.shared.controllerDisconnected(
                    name: name, anyStillConnected: stillConnected)
                if let goneID {
                    // Per-controller state keyed by object identity goes
                    // with the controller. Left behind, a later pad can be
                    // handed the same identity and inherit a stale haptic
                    // engine or a non-zero gyro accumulator, which shows up
                    // as no buzz or a one-time aim jump on reconnect.
                    FeedbackService.shared.forgetController(id: goneID)
                    self.forgetMotionState(id: goneID)
                }
                self.scheduleRefresh()
            }
        }

        // gamecontrolleragentd repaints the DualSense LED to the player
        // color on EVERY system focus change - not just when our own app's
        // active state flips. The app-level didResignActive/didBecomeActive
        // only fire on our own transitions, so once we're backgrounded,
        // switching between two OTHER apps let the daemon repaint and our
        // color never came back until our app was reactivated (exactly the
        // "switching windows again reverts it" behavior).
        //
        // NSWorkspace.didActivateApplicationNotification is posted to every
        // running app whenever ANY app becomes active, so a backgrounded
        // InputConfig still receives it. We re-assert on each activation
        // (including our own), which covers every case the app-local
        // notifications missed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleFocusChange() }
        }
    }

    /// Colors assigned to each controller slot
    static let slotColors: [(r: Float, g: Float, b: Float)] = [
        (0.2, 0.8, 0.4),  // green
        (0.6, 0.3, 0.8),  // purple
        (0.9, 0.3, 0.3),  // red
        (0.9, 0.6, 0.2),  // orange
        (0.2, 0.8, 0.8),  // cyan
        (0.9, 0.4, 0.6),  // pink
    ]

    /// Static snapshot of currently connected controllers. Used by the test
    /// bench so injectors can grab the first available controller without
    /// needing a reference to the service singleton.
    static func snapshotControllers() -> [GCController] {
        return GCController.controllers()
    }

    func refreshControllers() {
        #if DEBUG
        // Marketing capture: leave the synthetic controllers in place rather
        // than rebuilding the (empty) slot dict from real hardware.
        if marketingFakeActive { return }
        #endif
        // Capture light/RGB state by controller identity BEFORE we
        // rebuild the slot dict. After the rebuild we reassign by
        // identity rather than blind slot index - otherwise when a
        // low-numbered controller disconnects, every higher controller
        // shifts left and a custom color set for slot 1 silently
        // transfers to whatever controller now occupies slot 1.
        var lightByIdentity: [ObjectIdentifier: (r: Float, g: Float, b: Float)] = [:]
        var brightnessByIdentity: [ObjectIdentifier: UInt8] = [:]
        var rgbActiveByIdentity: Set<ObjectIdentifier> = []
        for (slot, c) in connectedControllers.enumerated() {
            let key = ObjectIdentifier(c)
            if let color = lightColors[slot] { lightByIdentity[key] = color }
            if let bri = lightBrightness[slot] { brightnessByIdentity[key] = bri }
            if rgbCycleActive[slot] == true { rgbActiveByIdentity.insert(key) }
        }

        let previousNames = controllerNames
        connectedControllers = GCController.controllers()
        controllerNames.removeAll()
        controllerDetails.removeAll()
        cachedExtraButtons.removeAll()
        dualSenseSlots.removeAll()
        // Drop press-logger bookkeeping for controllers that are gone, so the
        // wired set cannot grow across plug / unplug cycles.
        let liveControllerIDs = Set(connectedControllers.map(ObjectIdentifier.init))
        pressLoggerWired.formIntersection(liveControllerIDs)
        lightColors.removeAll()
        lightBrightness.removeAll()
        rgbCycleActive.removeAll()
        for (index, controller) in connectedControllers.enumerated() {
            // Restore per-controller-identity light state into the new slot.
            let key = ObjectIdentifier(controller)
            if let color = lightByIdentity[key] { lightColors[index] = color }
            if let bri = brightnessByIdentity[key] { lightBrightness[index] = bri }
            if rgbActiveByIdentity.contains(key) { rgbCycleActive[index] = true }
            cacheExtraButtons(for: controller, at: index)
            installPhysicalPressLogger(for: controller, slot: index)
            activateMotionSensors(for: controller)
            installTouchpadHandlers(for: controller, slot: index)
            installLiveInputHandler(for: controller)
            controllerNames[index] = controller.vendorName ?? "Controller \(index)"
            controllerDetails[index] = buildControllerInfo(controller)

            // Clear the player index up front so macOS doesn't assign a
            // player-number LED color it would later repaint over ours on
            // focus changes. See handleFocusChange() for the full rationale.
            controller.playerIndex = .indexUnset

            // Set light immediately
            setControllerLight(at: index)

            // Retry after a delay since some controllers need time after connection
            let idx = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setControllerLight(at: idx)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.setControllerLight(at: idx)
                // Update details again (battery may not be ready immediately)
                if idx < (self?.connectedControllers.count ?? 0) {
                    self?.controllerDetails[idx] = self?.buildControllerInfo(controller)
                }
            }
        }
        // Arrivals and departures, for the activity log. Compared by name
        // per slot, which is what the user sees in the sidebar.
        for (slot, name) in controllerNames where previousNames[slot] != name {
            let info = controllerDetails[slot]
            var caps: [String] = []
            if info?.supportsMotion == true { caps.append("motion") }
            if info?.hasLight == true { caps.append("light bar") }
            if info?.hasTouchpad == true { caps.append("touchpad") }
            ActivityLog.shared.info("Controllers", "Connected \(name) in slot \(slot)" + (caps.isEmpty ? "" : " (" + caps.joined(separator: ", ") + ")"), slot: slot)
        }
        for (slot, name) in previousNames where controllerNames[slot] != name {
            ActivityLog.shared.warning("Controllers", "Disconnected \(name) from slot \(slot)", slot: slot)
        }
        // Re-base the Steam and raw-HID virtual slots onto the new MFi slot
        // count and re-publish their metadata on this same main-actor turn.
        // refreshControllers just wiped controllerNames/controllerDetails and
        // only repopulated the MFi slots, and the base index (derived from
        // connectedControllers.count) has just shifted, so without this the
        // virtual slots would overlap or lose their metadata until the next
        // 0.5s sync tick.
        syncSteamControllerSlot()
        syncRawHIDGamepadSlots()
        // Re-enumerate the in-process LED writer so it picks up the new
        // controller set (handles hot-plug/unplug).
        InProcessLightWriter.shared.open()
        // With no controller left, stop hammering the LED so we don't spin the
        // re-assert timer for nothing.
        if connectedControllers.isEmpty { InProcessLightWriter.shared.stopHold() }

    }

    private func buildControllerInfo(_ controller: GCController) -> ControllerInfo {
        let profile = controller.physicalInputProfile
        var batteryLevel: Float?
        var batteryState: String?
        if let battery = controller.battery {
            batteryLevel = battery.batteryLevel
            switch battery.batteryState {
            case .charging: batteryState = "Charging"
            case .full: batteryState = "Full"
            case .discharging: batteryState = "Discharging"
            case .unknown: batteryState = "Unknown"
            @unknown default: batteryState = "Unknown"
            }
        }
        let buttonNames = Array(profile.buttons.keys).sorted()
        let hasTouchpad = buttonNames.contains(where: { $0.lowercased().contains("touchpad") })
        let pid = controller.productCategory

        return ControllerInfo(
            name: controller.vendorName ?? "Unknown Controller",
            productCategory: pid,
            hasExtendedGamepad: controller.extendedGamepad != nil,
            hasLight: controller.light != nil,
            hasBattery: controller.battery != nil,
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            // Real buttons only: the touchpad's finger components, thumbstick
            // and D-pad composites are not buttons a person can bind, and
            // counting them made a plain DualSense look like it had 34, which
            // the automatic layout then filled in with paddles.
            buttonCount: profile.buttons.keys.filter { name in
                !Self.ignoredProfileNames.contains(where: { name.contains($0) })
            }.count,
            axisCount: profile.axes.count,
            supportsMotion: controller.motion != nil,
            connectedAt: Date(),
            hasTouchpad: hasTouchpad,
            hasMicroGamepad: controller.microGamepad != nil,
            hasAdaptiveTriggers: pid.lowercased().contains("dualsense"),
            physicalButtonNames: buttonNames,
            brand: ControllerTypeDetector.detect(controller)
        )
    }

    /// Angle turned since the engine last read a controller, per controller,
    /// summed from every sensor sample as it arrives. The poll loop runs at
    /// 120 Hz but a Bluetooth controller delivers motion in bursts, so
    /// reading `rotationRate` at poll time sees only the latest sample and
    /// misses the rest of a fast flick. Integrating in the sensor callback
    /// makes the pointer travel a distance that depends only on how far the
    /// controller turned, not on how quickly.
    private struct GyroAccumulator {
        var angle = SIMD3<Float>(repeating: 0)   // radians since last drain
        var lastSample: CFTimeInterval = 0
        var lastDrain: CFTimeInterval = 0
        var samples = 0
        /// Raw rate averaged over roughly the last half second, for re-zero
        /// (one sample is too noisy to zero on) and drift learning.
        var mean = SIMD3<Float>(repeating: 0)
        /// How much the raw rate wobbles around that mean (same time
        /// constant). Small wobble plus 1 g on the accelerometer means the
        /// controller is physically still, whatever the current bias says.
        var jitter = SIMD3<Float>(repeating: 0)
        /// When the controller was last judged to be moving.
        var lastMotion: CFTimeInterval = 0
        /// Largest |rate| seen per axis since the debug readout last asked.
        var peak = SIMD3<Float>(repeating: 0)
    }

    #if DEBUG
    /// Peak |rate| per axis since the last call, for the debug readout.
    func debugTakePeakRate(for controller: GCController) -> SIMD3<Float> {
        gyroLock.lock(); defer { gyroLock.unlock() }
        let id = ObjectIdentifier(controller)
        let p = gyroAccumulators[id]?.peak ?? .zero
        gyroAccumulators[id]?.peak = .zero
        return p
    }
    #endif
    private var gyroAccumulators: [ObjectIdentifier: GyroAccumulator] = [:]
    private let gyroLock = NSLock()

    #if DEBUG
    /// Total sensor callbacks seen for a controller, for the debug readout.
    func debugGyroSampleCount(for controller: GCController) -> Int {
        gyroLock.lock(); defer { gyroLock.unlock() }
        return gyroTotalSamples[ObjectIdentifier(controller)] ?? 0
    }
    private var gyroTotalSamples: [ObjectIdentifier: Int] = [:]
    #endif

    private func installGyroIntegrator(_ motion: GCMotion, for controller: GCController) {
        let key = ObjectIdentifier(controller)
        gyroLock.lock()
        if gyroAccumulators[key] == nil { gyroAccumulators[key] = GyroAccumulator() }
        gyroLock.unlock()
        motion.valueChangedHandler = { [weak self] m in
            guard let self, m.hasRotationRate else { return }
            let now = CACurrentMediaTime()
            let r = m.rotationRate
            self.gyroLock.lock()
            var acc = self.gyroAccumulators[key] ?? GyroAccumulator()
            // First sample after a pause has no interval to integrate over;
            // clamp long gaps so a stall does not land as one giant step.
            let dt = acc.lastSample == 0 ? 0 : min(0.05, now - acc.lastSample)
            let sample = SIMD3(Float(r.x), Float(r.y), Float(r.z))
            acc.angle += sample * Float(dt)
            acc.peak = SIMD3(max(acc.peak.x, abs(sample.x)), max(acc.peak.y, abs(sample.y)), max(acc.peak.z, abs(sample.z)))
            // EMA with a 0.5 s time constant.
            let alpha = dt > 0 ? Float(1 - exp(-dt / 0.5)) : 1
            acc.mean += (sample - acc.mean) * alpha
            let dev = SIMD3(abs(sample.x - acc.mean.x), abs(sample.y - acc.mean.y), abs(sample.z - acc.mean.z))
            acc.jitter += (dev - acc.jitter) * alpha
            acc.lastSample = now
            acc.samples += 1
            self.gyroAccumulators[key] = acc
            #if DEBUG
            self.gyroTotalSamples[key, default: 0] += 1
            #endif
            self.gyroLock.unlock()
        }
    }

    /// Pitch (rotation about the controller's X axis) with an absolute
    /// reference. The gyro integral alone can only be as good as the samples
    /// it saw, and a hard slam can outrun the sensor; the accelerometer,
    /// however, always knows which way is down once the controller is still.
    /// This fuses the two: the gyro carries the motion, and whenever the
    /// controller is quiet the estimate eases onto the accelerometer's
    /// angle, so "back to flat" always means "back to zero" in the end. The
    /// sign relating the two is learned from the first real movement rather
    /// than assumed, so a differently mounted sensor still works.
    private struct AxisFusion {
        var estimate: Float = 0          // radians, fused
        var gyroOnly: Float = 0          // radians, gyro integral alone
        var lastAccelAngle: Float = 0
        var lastGyroOnly: Float = 0
        var correlation: Float = 0
        /// +1 from the measured frame (X right, Y forward, Z up out of the
        /// face, right-handed): nose up makes both the gyro X integral and
        /// the accelerometer pitch positive; right side down does the same
        /// for gyro Y and accelerometer roll. Flipped only if real movement
        /// proves otherwise.
        var sign: Float = 1
        var seeded = false
        var lastCorrectedRate = SIMD3<Float>(repeating: 0)
    }
    private struct FusionKey: Hashable { let controller: ObjectIdentifier; let channel: MotionChannel }
    private var axisFusion: [FusionKey: AxisFusion] = [:]
    static let motionRezeroedNotification = Notification.Name("InputConfig.motionRezeroed")

    /// The accelerometer's angle for a tilt axis, from the gravity direction
    /// it reports (down, in the controller's frame; (0, 0, -1) when flat).
    /// Rotation rate about gravity, positive when the pad turns clockwise
    /// seen from above (pointing right). Nil when the accelerometer is not
    /// reading gravity cleanly, in which case the caller uses the pad's own
    /// Z rate, which is the same thing for a pad held flat.
    private func worldYawRate(gx: Float, gy: Float, gz: Float, motion: GCMotion) -> Float? {
        var g: SIMD3<Float>
        if motion.hasGravityAndUserAcceleration {
            g = SIMD3(Float(motion.gravity.x), Float(motion.gravity.y), Float(motion.gravity.z))
        } else {
            let a = motion.acceleration
            g = SIMD3(Float(a.x), Float(a.y), Float(a.z))
            let mag = (g * g).sum().squareRoot()
            guard mag.isFinite, abs(mag - 1) < 0.15 else { return nil }
        }
        let mag = (g * g).sum().squareRoot()
        guard mag.isFinite, mag > 0.5 else { return nil }
        g /= mag
        // Gravity points down. Turning right is clockwise from above, which is
        // a negative rotation about up, so a positive rotation about down.
        let rate = gx * g.x + gy * g.y + gz * g.z
        return rate.isFinite ? rate : nil
    }

    private static func accelAngle(_ channel: MotionChannel, ax: Float, ay: Float, az: Float) -> Float {
        switch channel {
        case .gyroX: return atan2(-ay, (ax * ax + az * az).squareRoot())   // pitch: nose up +
        case .gyroY: return atan2(ax, (ay * ay + az * az).squareRoot())    // roll: right side down +
        default: return 0
        }
    }

    #if DEBUG
    func debugPitchFusion(for controller: GCController) -> String {
        let id = ObjectIdentifier(controller)
        guard let f = axisFusion[FusionKey(controller: id, channel: .gyroX)] else { return "fusion: none" }
        let r = axisFusion[FusionKey(controller: id, channel: .gyroY)]
        let key = MotionCalibrationService.identityKey(for: controller)
        let cal = MotionCalibrationService.shared.calibration(forKey: key)
        return String(format: "fusion: pitch sign=%+.0f est=%.4f gyroOnly=%.4f accel=%.4f | roll sign=%+.0f est=%.4f gyroOnly=%.4f accel=%.4f | corrected x=%+.4f y=%+.4f z=%+.4f | stored drift x=%.5f y=%.5f z=%.5f",
                      f.sign, f.estimate, f.gyroOnly, f.lastAccelAngle,
                      r?.sign ?? 0, r?.estimate ?? 0, r?.gyroOnly ?? 0, r?.lastAccelAngle ?? 0,
                      f.lastCorrectedRate.x, f.lastCorrectedRate.y, f.lastCorrectedRate.z,
                      cal?.gyroDriftX ?? 0, cal?.gyroDriftY ?? 0, cal?.gyroDriftZ ?? 0)
    }
    #endif

    /// Fused tilt about one axis this poll: the gyro's own change, the extra
    /// correction from the accelerometer, and the absolute angle. Nil
    /// without an accelerometer. A complementary filter that runs
    /// continuously whenever the accelerometer is reading gravity and not
    /// the hand, so there is no lump after a movement stops: it eases in
    /// over a few tenths of a second and never steps more than about a
    /// degree per poll.
    private func fuseTilt(_ channel: MotionChannel, controller: GCController, motion: GCMotion,
                          gyroRate: Float, interval: Float,
                          corrected: SIMD3<Float>) -> (gyro: Float, correction: Float, absolute: Float)? {
        let a = motion.acceleration
        let ax = Float(a.x), ay = Float(a.y), az = Float(a.z)
        let mag = (ax * ax + ay * ay + az * az).squareRoot()
        guard mag.isFinite, mag > 0.2 else { return nil }
        let key = FusionKey(controller: ObjectIdentifier(controller), channel: channel)
        var f = axisFusion[key] ?? AxisFusion()
        f.lastCorrectedRate = corrected
        let accelAngle = Self.accelAngle(channel, ax: ax, ay: ay, az: az)
        let gravityOnly = abs(mag - 1) < 0.1
        let gyroDelta = gyroRate * interval
        f.gyroOnly += gyroDelta
        f.estimate += gyroDelta
        if !f.seeded {
            f.lastAccelAngle = accelAngle; f.lastGyroOnly = f.gyroOnly; f.seeded = true
            f.estimate = f.sign * accelAngle
        }
        if gravityOnly {
            let dA = max(-0.2, min(0.2, accelAngle - f.lastAccelAngle))
            let dG = max(-0.2, min(0.2, f.gyroOnly - f.lastGyroOnly))
            f.correlation = max(-1, min(1, f.correlation + dA * dG))
            if f.correlation < -0.05 { f.sign = -1 } else if f.correlation > 0.05 { f.sign = 1 }
        }
        f.lastAccelAngle = accelAngle; f.lastGyroOnly = f.gyroOnly
        var correction: Float = 0
        if gravityOnly, abs(gyroRate) < 1.5 {
            let tau: Float = abs(gyroRate) < 0.05 ? 0.2 : 0.6
            let k = 1 - expf(-interval / tau)
            correction = (f.sign * accelAngle - f.estimate) * k
            correction = max(-0.02, min(0.02, correction))
            f.estimate += correction
        }
        axisFusion[key] = f
        return (gyroDelta, correction, f.estimate)
    }

    /// Drop the gyro accumulator and fusion state of a controller that left.
    func forgetMotionState(id: ObjectIdentifier) {
        gyroLock.lock(); gyroAccumulators.removeValue(forKey: id); gyroLock.unlock()
        for channel in MotionChannel.allCases {
            axisFusion.removeValue(forKey: FusionKey(controller: id, channel: channel))
        }
    }

    /// The raw rate averaged over the last half second, or the instantaneous
    /// value when no samples have arrived yet.
    private func meanRawGyroRate(for controller: GCController) -> SIMD3<Float>? {
        gyroLock.lock(); defer { gyroLock.unlock() }
        guard let acc = gyroAccumulators[ObjectIdentifier(controller)], acc.samples >= 0, acc.lastSample > 0 else { return nil }
        return acc.mean
    }

    /// Below this drift-corrected rate (rad/s, about 0.6 degrees per second)
    /// a controller counts as lying still. Shared with the engine's rest gate.
    static let motionRestLimit: Float = 0.01

    /// Drift learning: once the controller has been still for a second, ease
    /// the stored zero toward what it is reading, so slow sensor wander never
    /// becomes pointer creep and nobody has to recalibrate.
    private func learnGyroDrift(controller: GCController, motion: GCMotion,
                                corrected g: SIMD3<Float>, interval: Float, key: String) {
        let id = ObjectIdentifier(controller)
        let now = CACurrentMediaTime()
        let a = motion.acceleration
        let mag = Float((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
        gyroLock.lock()
        var acc = gyroAccumulators[id] ?? GyroAccumulator()
        // Still means: the raw rate is steady (hand tremor and real motion
        // both wobble it) and the accelerometer reads gravity and nothing
        // else. Deliberately not "corrected rate is small", which a wrong
        // bias would fail forever.
        let steady = acc.jitter.x < 0.006 && acc.jitter.y < 0.006 && acc.jitter.z < 0.006
        let onlyGravity = !mag.isFinite || abs(mag - 1) < 0.05
        let still = steady && onlyGravity && acc.samples >= 0 && acc.lastSample > 0
        if !still { acc.lastMotion = now }
        if acc.lastMotion == 0 { acc.lastMotion = now }
        let restingFor = now - acc.lastMotion
        let mean = acc.mean
        gyroAccumulators[id] = acc
        gyroLock.unlock()
        guard still, restingFor > 1.0 else { return }
        // Ease the stored zero toward the steady raw reading: 10% per poll
        // settles in a tenth of a second and also heals a zero that was
        // taken while moving.
        guard let cal = MotionCalibrationService.shared.calibration(forKey: key) else {
            MotionCalibrationService.shared.quickZero(forKey: key, gyroX: mean.x, gyroY: mean.y, gyroZ: mean.z,
                                                      accelX: 0, accelY: 0, accelZ: 0)
            return
        }
        let k: Float = 0.1
        MotionCalibrationService.shared.nudgeGyroDrift(dx: (mean.x - cal.gyroDriftX) * k,
                                                      dy: (mean.y - cal.gyroDriftY) * k,
                                                      dz: (mean.z - cal.gyroDriftZ) * k, forKey: key)
    }

    /// True when the controller has been physically still for the last
    /// half second (steady gyro, 1 g on the accelerometer).
    private func isPhysicallyStill(_ controller: GCController, motion: GCMotion) -> Bool {
        let a = motion.acceleration
        let mag = Float((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
        gyroLock.lock(); defer { gyroLock.unlock() }
        guard let acc = gyroAccumulators[ObjectIdentifier(controller)] else { return false }
        return acc.jitter.x < 0.006 && acc.jitter.y < 0.006 && acc.jitter.z < 0.006
            && (!mag.isFinite || abs(mag - 1) < 0.05)
    }

    /// The angle turned since the last drain (every sample counted) and the
    /// length of that interval. `angle` is nil when no sample arrived, in
    /// which case the caller integrates the instantaneous rate over the
    /// interval instead.
    private func drainGyro(for controller: GCController) -> (angle: SIMD3<Float>?, interval: Float) {
        let key = ObjectIdentifier(controller)
        let now = CACurrentMediaTime()
        gyroLock.lock(); defer { gyroLock.unlock() }
        var acc = gyroAccumulators[key] ?? GyroAccumulator()
        let interval = acc.lastDrain > 0 ? Float(min(0.1, max(1.0 / 1000.0, now - acc.lastDrain))) : 1.0 / 120.0
        let angle: SIMD3<Float>? = acc.samples > 0 ? acc.angle : nil
        acc.angle = .zero; acc.samples = 0; acc.lastDrain = now
        gyroAccumulators[key] = acc
        return (angle, interval)
    }

    /// Ask the controller's `GCMotion` to start reporting gyro and
    /// accelerometer data. Some controllers (Switch Pro, Joy-Con, and some
    /// Bluetooth-paired DualSense / DualShock 4) require explicit activation
    /// before `motion.rotationRate` / `motion.userAcceleration` return
    /// anything other than zero. Apple exposes this via
    /// `sensorsRequireManualActivation` + `sensorsActive`; setting
    /// `sensorsActive = true` is a no-op for controllers that don't require
    /// it, so we always set it.
    private func activateMotionSensors(for controller: GCController) {
        guard let motion = controller.motion else { return }
        // Force activation regardless of `sensorsRequireManualActivation`:
        // it's safe on controllers that auto-activate and required on the
        // ones that don't.
        motion.sensorsActive = true
        installGyroIntegrator(motion, for: controller)
        #if DEBUG
        print("[GCS] Motion activated for \(controller.vendorName ?? "?")"
              + " manual=\(motion.sensorsRequireManualActivation)"
              + " active=\(motion.sensorsActive)"
              + " hasRotation=\(motion.hasRotationRate)"
              + " hasAttitude=\(motion.hasAttitude)"
              + " hasGravity=\(motion.hasGravityAndUserAcceleration)")
        #endif
    }

    /// Pre-compute the mapping of extra physical profile buttons for a controller.
    /// This runs once on connection so readControllerState doesn't rebuild it every frame.
    private func cacheExtraButtons(for controller: GCController, at index: Int) {
        // Cache the DualSense check here, once per connection. It is a
        // connection-lifetime constant, and recomputing it per poll frame
        // cost two String.lowercased() allocations per slot.
        let nameBlob = ((controller.vendorName ?? "") + " " + controller.productCategory).lowercased()
        if nameBlob.contains("dualsense") {
            dualSenseSlots.insert(index)
        }
        guard let gamepad = controller.extendedGamepad else {
            // Profile-only devices (a solo Joy-Con, a remote, an adaptive
            // board with no gamepad profile) get the same treatment as the
            // extras on a gamepad: every button gets one stable index that
            // the state read, Scan, the press log and the automatic layout
            // all share. Known names take their standard index; anything
            // else takes a dynamic index from 20 up, in name order. Before
            // this, unknown names fell back to "digits in the name", which
            // mapped SL, SR and every letter-named button onto A.
            var result: [(GCControllerButtonInput, Int)] = []
            var nextDynamic = 20
            for (name, button) in controller.physicalInputProfile.buttons.sorted(by: { $0.key < $1.key }) {
                if Self.ignoredProfileNames.contains(where: { name.contains($0) }) { continue }
                if let known = Self.knownButtonMap[name] {
                    result.append((button, known))
                } else {
                    result.append((button, nextDynamic)); nextDynamic += 1
                }
            }
            cachedExtraButtons[index] = result
            return
        }

        var handledObjects = Set<ObjectIdentifier>()
        handledObjects.insert(ObjectIdentifier(gamepad.buttonA))
        handledObjects.insert(ObjectIdentifier(gamepad.buttonB))
        handledObjects.insert(ObjectIdentifier(gamepad.buttonX))
        handledObjects.insert(ObjectIdentifier(gamepad.buttonY))
        handledObjects.insert(ObjectIdentifier(gamepad.leftShoulder))
        handledObjects.insert(ObjectIdentifier(gamepad.rightShoulder))
        handledObjects.insert(ObjectIdentifier(gamepad.leftTrigger as GCControllerButtonInput))
        handledObjects.insert(ObjectIdentifier(gamepad.rightTrigger as GCControllerButtonInput))
        if let o = gamepad.buttonOptions { handledObjects.insert(ObjectIdentifier(o)) }
        if let m = gamepad.buttonMenu as GCControllerButtonInput? { handledObjects.insert(ObjectIdentifier(m)) }
        if let h = gamepad.buttonHome { handledObjects.insert(ObjectIdentifier(h)) }
        if let l = gamepad.leftThumbstickButton { handledObjects.insert(ObjectIdentifier(l)) }
        if let r = gamepad.rightThumbstickButton { handledObjects.insert(ObjectIdentifier(r)) }

        var result: [(GCControllerButtonInput, Int)] = []
        var nextDynamic = 20

        // Apple's GameController framework exposes the DualSense touchpad
        // click and microphone button on a specific subclass, not through
        // the standard physical profile, so cast and pull them explicitly.
        // This ensures the touchpad always maps to index 13 (and mic to 15)
        // regardless of how the physical profile names them.
        if let dualSense = gamepad as? GCDualSenseGamepad {
            result.append((dualSense.touchpadButton, 13))
            handledObjects.insert(ObjectIdentifier(dualSense.touchpadButton))
        }
        if let dualShock = gamepad as? GCDualShockGamepad,
           let touchpad = dualShock.touchpadButton {
            result.append((touchpad, 13))
            handledObjects.insert(ObjectIdentifier(touchpad))
        }

        // KVC-based discovery for buttons that Apple's typed classes
        // expose but aren't in every SDK: microphoneButton (DualSense
        // mute), and the Edge-specific paddle / function buttons. We
        // ask the runtime whether the property is there - if so, pull
        // the button via `value(forKey:)` and register it with a stable
        // index. This makes the Edge's hardware buttons reachable
        // without depending on a build-time `GCDualSenseEdgeGamepad`
        // symbol that this SDK may not contain.
        let kvcSpecial: [(String, Int)] = [
            ("microphoneButton",      15),
            ("leftPaddleButton",      16),
            ("rightPaddleButton",     17),
            ("leftFunctionButton",    20),
            ("rightFunctionButton",   21)
        ]
        let ns = gamepad as NSObject
        for (key, btnIndex) in kvcSpecial {
            guard ns.responds(to: NSSelectorFromString(key)) else { continue }
            guard let button = ns.value(forKey: key) as? GCControllerButtonInput else { continue }
            // Skip if we somehow already registered this exact button.
            if handledObjects.contains(ObjectIdentifier(button)) { continue }
            result.append((button, btnIndex))
            handledObjects.insert(ObjectIdentifier(button))
            #if DEBUG
            print("[GCS] KVC discovered \(key) -> btn \(btnIndex) on \(controller.vendorName ?? "?")")
            #endif
        }

        // Diagnostic: log every button name the profile reports the
        // moment we cache. NSLog (not print) so it reaches the unified
        // log immediately and survives across-process redirects - lets
        // the user see via `log stream` in Terminal exactly which
        // names Apple's framework is sending. If the PS / mute /
        // paddle / FN buttons don't appear here AND none were found
        // via KVC above, Apple's framework isn't sending them and we
        // can't map them through standard MFi APIs.
        let profileButtonNames = Array(controller.physicalInputProfile.buttons.keys).sorted()
        NSLog("[GCS] Profile button names for %@ (slot %d): %@",
              controller.vendorName ?? "?",
              index,
              profileButtonNames.joined(separator: ", "))
        NSLog("[GCS] cacheExtraButtons -> %d entries: %@",
              result.count,
              result.map { "\($0.1)" }.joined(separator: ", "))

        for (name, button) in controller.physicalInputProfile.buttons.sorted(by: { $0.key < $1.key }) {
            if handledObjects.contains(ObjectIdentifier(button)) { continue }
            if Self.ignoredProfileNames.contains(where: { name.contains($0) }) { continue }

            let btnIndex: Int
            if let known = Self.knownButtonMap[name] {
                btnIndex = known
            } else {
                let lower = name.lowercased()
                if lower.contains("touchpad") || lower.contains("pad button") {
                    btnIndex = 13
                } else if lower.contains("share") || lower.contains("create") || lower.contains("capture") {
                    btnIndex = 14
                } else if lower.contains("mute") || lower.contains("microphone") {
                    btnIndex = 15
                } else {
                    btnIndex = nextDynamic
                    nextDynamic += 1
                }
            }
            result.append((button, btnIndex))
        }

        cachedExtraButtons[index] = result

        // Extra analogue inputs. An accessory plugged into an Access
        // Controller or an Xbox Adaptive Controller (a third trigger, a
        // pedal, a proportional joystick) shows up in the profile as an
        // axis past the six a standard pad has. Give each one a stable
        // index from 6 up so it can be read, drawn, and bound like any
        // other axis.
        let standardAxisNames: Set<String> = [
            "Left Thumbstick X Axis", "Left Thumbstick Y Axis",
            "Right Thumbstick X Axis", "Right Thumbstick Y Axis",
            "Direction Pad X Axis", "Direction Pad Y Axis",
        ]
        var axisResult: [(GCControllerAxisInput, Int, String)] = []
        var nextAxis = 6
        for (name, axis) in controller.physicalInputProfile.axes.sorted(by: { $0.key < $1.key })
        where !standardAxisNames.contains(name) {
            // The touchpad's finger positions are axes too, with raw HID
            // names on some controllers; they belong to the touchpad path,
            // not to the accessory list.
            let lower = (axis.localizedName ?? name).lowercased() + " " + name.lowercased()
            if lower.contains("touchpad") { continue }
            axisResult.append((axis, nextAxis, axis.localizedName ?? name))
            nextAxis += 1
        }
        cachedExtraAxes[index] = axisResult
        // The profile's shape is what tells us an accessory arrived or
        // left; remember it so the watcher below can notice a change.
        profileShape[index] = controller.physicalInputProfile.elements.count
    }

    /// Extra analogue inputs per slot, discovered from the profile.
    private var cachedExtraAxes: [Int: [(GCControllerAxisInput, Int, String)]] = [:]
    /// Element count per slot, to spot an accessory being plugged in or out.
    private var profileShape: [Int: Int] = [:]

    /// Accessories can be plugged into a controller that is already
    /// connected: a switch into an Access Controller's expansion port, a
    /// button or pedal into an Xbox Adaptive Controller. macOS sends no
    /// notification for that, so the profile's element count is checked a
    /// few times a second and the slot re-read when it changes. Cheap: one
    /// integer compare per controller per tick.
    private func startAccessoryWatch() {
        guard accessoryWatchTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for (index, controller) in self.connectedControllers.enumerated() {
                    // A DualSense needs its motion sensors switched on by
                    // hand, and anything else that opens the controller can
                    // switch them off again, which reads as "the gyro
                    // stopped working". Re-assert it while we are here.
                    if let motion = controller.motion, !motion.sensorsActive {
                        motion.sensorsActive = true
                        self.installGyroIntegrator(motion, for: controller)
                        ActivityLog.shared.info("Controllers",
                            "Motion sensors re-enabled on \(controller.vendorName ?? "controller")")
                    }
                    let shape = controller.physicalInputProfile.elements.count
                    guard self.profileShape[index] != shape else { continue }
                    ActivityLog.shared.info("Controllers",
                        "\(controller.vendorName ?? "Controller") changed shape (\(shape) inputs): re-reading its accessories")
                    self.cacheExtraButtons(for: controller, at: index)
                    self.controllerDetails[index] = self.buildControllerInfo(controller)
                    // A scan in progress should hear the new control too.
                    if self.isScanning { self.setupScanHandlers(for: controller, index: index) }
                }
            }
        }
        accessoryWatchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private var accessoryWatchTimer: Timer?

    /// The slot a device with this name is connected to, if any. Picking a
    /// device from an input device's menu names it; this is what turns that
    /// name back into the controller whose inputs should be read for that
    /// group, so choosing a DualSense on a group that was set up for an
    /// Access Controller really does switch to the DualSense.
    func slot(forDeviceNamed name: String) -> Int? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        for (slot, info) in controllerDetails where info.name.lowercased() == wanted { return slot }
        for (slot, n) in controllerNames where n.lowercased() == wanted { return slot }
        for (slot, info) in controllerDetails
        where info.name.lowercased().contains(wanted) || wanted.contains(info.name.lowercased()) {
            return slot
        }
        return nil
    }

    /// The controller an input device group should read. In order: the
    /// device picked from its menu when that device is connected; then, if
    /// the group binds motion or the touchpad and the controller at its own
    /// position has neither, the connected controller that does (so a gyro
    /// preset works when the gyro controller is not the first one plugged
    /// in); otherwise the slot with the same number as the group.
    func effectiveSlot(for mapping: JoystickMapping, groupIndex: Int) -> Int {
        if let name = mapping.customName, let picked = slot(forDeviceNamed: name) {
            return picked
        }
        let own = controllerDetails[groupIndex]
        let usesMotion = mapping.bindings.contains { $0.input.type == .motion }
        if usesMotion, own?.supportsMotion != true,
           let capable = controllerDetails.filter({ $0.value.supportsMotion })
            .keys.sorted().first {
            return capable
        }
        let usesTouchpad = mapping.bindings.contains {
            [.touchpad, .touchpadRegion, .touchpadGesture].contains($0.input.type)
        }
        if usesTouchpad, own?.hasTouchpad != true,
           let capable = controllerDetails.filter({ $0.value.hasTouchpad })
            .keys.sorted().first {
            return capable
        }
        return groupIndex
    }

    func controllerName(at index: Int) -> String {
        if index < connectedControllers.count {
            return connectedControllers[index].vendorName ?? "Controller \(index)"
        }
        // Steam Controller virtual slot just past the real MFi ones.
        if let steamSlot = steamControllerSlot, index == steamSlot {
            return "Steam Controller"
        }
        #if DEBUG
        // Marketing capture: name the synthetic controllers so the visualizer
        // header reads like a real session instead of "No controller in slot".
        if marketingFakeActive, let name = controllerNames[index] { return name }
        #endif
        return "No controller in slot \(index)"
    }

    /// Set the controller's light bar color (DualSense, DualShock 4)
    func setControllerLight(at index: Int) {
        guard index < connectedControllers.count else { return }
        // A running preset's colour outranks both the stored colour and the
        // slot default, so reconnecting a controller cannot change the light
        // out from under an active preset.
        if let o = presetLightOverride {
            applyTemporaryLight(at: index, red: o.r, green: o.g, blue: o.b, brightness: o.brightness)
            return
        }
        // Use stored custom color if set, otherwise use slot default
        if let custom = lightColors[index] {
            applyLight(at: index, red: custom.r, green: custom.g, blue: custom.b)
        } else {
            let colorIndex = index % Self.slotColors.count
            let color = Self.slotColors[colorIndex]
            applyLight(at: index, red: color.r, green: color.g, blue: color.b)
        }
    }

    /// Set a custom light color on a controller
    func setControllerLight(at index: Int, red: Float, green: Float, blue: Float) {
        guard index < connectedControllers.count else { return }
        lightColors[index] = (r: red, g: green, b: blue)
        applyLight(at: index, red: red, green: green, blue: blue)
    }

    /// Set light brightness (0=off, 1=dim, 2=bright) by scaling the RGB values
    func setControllerBrightness(at index: Int, brightness: UInt8) {
        guard index < connectedControllers.count else { return }
        lightBrightness[index] = brightness
        if let custom = lightColors[index] {
            applyLight(at: index, red: custom.r, green: custom.g, blue: custom.b)
        } else {
            setControllerLight(at: index)
        }
    }

    /// Last RGB (already brightness-scaled, 0-255) written per slot. macOS
    /// repaints the DualSense light to its default on focus changes, so we
    /// re-assert this on every system app activation (see the NSWorkspace
    /// observer in init) to keep the user's / preset's color showing.
    private var lastAppliedColor: [Int: (r: UInt8, g: UInt8, b: UInt8)] = [:]

    /// Last color the RGB rainbow wrote (brightness-scaled, 0-255). When a
    /// focus change interrupts the cycle we snap straight back to THIS color
    /// so the rainbow stays visually continuous across an app switch instead
    /// of flashing the system default.
    private var lastRGBColor: (r: UInt8, g: UInt8, b: UInt8)?

    /// Re-assert the current color via the in-process writer - instant, no
    /// subprocess spawn, no daemon kill - so an app switch snaps back to our
    /// color as fast as possible. During the RGB cycle we re-send the exact
    /// last rainbow color; otherwise each slot's last applied color.
    func reassertLights() {
        if rgbCycleActive.values.contains(true) {
            if let c = lastRGBColor {
                InProcessLightWriter.shared.write(red: c.r, green: c.g, blue: c.b)
            }
            return
        }
        for (_, c) in lastAppliedColor {
            InProcessLightWriter.shared.write(red: c.r, green: c.g, blue: c.b)
        }
    }

    /// Defense against the focus-change LED repaint. gamecontrolleragentd
    /// repaints the LED on every system focus change; we (1) clear the
    /// player index so it has no player color to repaint TO, and (2)
    /// re-assert our color via the in-process writer on a tight burst of
    /// delays so our write wins the instant the daemon repaints. In-process
    /// writes are essentially free, so we fire several inside the first
    /// ~400 ms to make the correction as fast and smooth as possible.
    private func handleFocusChange() {
        clearPlayerIndices()
        reassertLights()
        for delay in [0.02, 0.05, 0.1, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.clearPlayerIndices()
                self?.reassertLights()
            }
        }
    }

    /// Set every connected controller's player index to "unset" so macOS
    /// shows no player-number LED color. Cheap and idempotent; safe to
    /// call repeatedly. Nothing else in the app keys off `playerIndex`
    /// (slot numbering is by array index), so clearing it has no side
    /// effects beyond suppressing the system LED color.
    private func clearPlayerIndices() {
        for c in connectedControllers {
            c.playerIndex = .indexUnset
        }
    }

    /// RGB cycle mode
    @Published var rgbCycleActive: [Int: Bool] = [:]
    private var rgbHue: Float = 0
    /// Drives the live RGB rainbow. A single shared timer services every
    /// slot with the cycle enabled (the LED write targets all Sony
    /// controllers, matching the rest of the light path).
    private var rgbTimer: Timer?
    /// Base loop length and LED update rate. 40 Hz makes the rainbow
    /// seamless; the user-facing speed slider scales the per-tick hue
    /// advance via `rgbCycleSpeed`.
    private let rgbFullLoopSeconds: Double = 3.0
    private let rgbUpdateHz: Double = 40.0
    /// User-adjustable cycle speed (the slider in every RGB menu). 1.0 = one
    /// full rainbow every `rgbFullLoopSeconds`; higher = faster. Persisted so
    /// the choice sticks across launches.
    @Published var rgbCycleSpeed: Double =
        (UserDefaults.standard.object(forKey: "InputConfig.rgbCycleSpeed") as? Double) ?? 1.0 {
        didSet { UserDefaults.standard.set(rgbCycleSpeed, forKey: "InputConfig.rgbCycleSpeed") }
    }
    /// Throttle so we publish to `lightColors` (the UI swatch) at ~10 Hz
    /// instead of the full LED rate, avoiding a 40 Hz SwiftUI re-render storm.
    private var rgbTickCount: Int = 0

    func toggleRGBCycle(at index: Int) {
        if rgbCycleActive[index] == true {
            stopRGBCycle(at: index)
        } else {
            startRGBCycle(at: index)
        }
    }

    private func startRGBCycle(at index: Int) {
        rgbCycleActive[index] = true
        // The cycle feeds its color into the same background hammer as solid
        // colors (via rgbTick -> startHold), so it survives app-switch throttling.
        // Re-enumerate + open the controller(s) for fast, subprocess-free
        // writes (kept open afterwards for the focus-change re-assert).
        InProcessLightWriter.shared.open()
        guard rgbTimer == nil else { return }   // shared timer already running
        // Do NOT reset rgbHue here: keep the rainbow's current position so the
        // cycle resumes where it left off rather than snapping back to red when
        // it restarts (e.g. after setting a color or a menu round-trip).
        rgbTickCount = 0
        let timer = Timer(timeInterval: 1.0 / rgbUpdateHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rgbTick() }
        }
        rgbTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One frame of the rainbow: advance the hue (scaled by the speed
    /// slider), write it straight to the LED via the in-process writer, and
    /// (throttled) update the UI swatch.
    private func rgbTick() {
        // Stop once no slot wants the cycle anymore. We leave the in-process
        // writer open so the focus-change re-assert stays instant.
        guard rgbCycleActive.values.contains(true) else {
            rgbTimer?.invalidate(); rgbTimer = nil
            return
        }

        let (r, g, b) = Self.hsbToRGB(h: rgbHue, s: 1.0, b: 1.0)
        // Honor the brightness of the first active slot the same way
        // applyLight() does - pre-scale the RGB; the report's brightness
        // byte stays at its default.
        let bri = rgbCycleActive.first(where: { $0.value })
            .flatMap { lightBrightness[$0.key] } ?? 2
        let scale: Float = switch bri { case 0: 0.0; case 1: 0.25; default: 1.0 }
        let r8 = UInt8(min(max(r * scale * 255, 0), 255))
        let g8 = UInt8(min(max(g * scale * 255, 0), 255))
        let b8 = UInt8(min(max(b * scale * 255, 0), 255))
        // Feed the rainbow frame into the background hammer (200 Hz) instead of
        // writing once from this main-thread timer, which the OS throttles on
        // app switch (causing the LED to flash to the system default mid-cycle).
        InProcessLightWriter.shared.startHold(red: r8, green: g8, blue: b8)
        lastRGBColor = (r8, g8, b8)   // snap-back target for app switches

        // Publish to the UI swatch at ~10 Hz, not the full 40 Hz LED rate.
        rgbTickCount += 1
        if rgbTickCount % 4 == 0 {
            for (slot, on) in rgbCycleActive where on { lightColors[slot] = (r, g, b) }
        }

        // Hue advance per tick scaled by the speed slider (clamped so the
        // cycle can't stall or run away).
        let speed = min(max(rgbCycleSpeed, 0.1), 8.0)
        rgbHue += Float(speed / (rgbFullLoopSeconds * rgbUpdateHz))
        if rgbHue > 1.0 { rgbHue -= 1.0 }
    }

    func stopRGBCycle(at index: Int) {
        rgbCycleActive[index] = false
        // Tear down the shared timer only when no slot is still cycling.
        guard !rgbCycleActive.values.contains(true) else { return }
        rgbTimer?.invalidate(); rgbTimer = nil
        lastRGBColor = nil
        // Freeze on the current color and route it through the normal path
        // so the focus-change re-assert keeps showing it.
        setControllerLight(at: index)
    }

    /// Stop the rainbow on every slot at once. Called when a preset with a
    /// light-bar color activates so the preset's color overrides the cycle
    /// instead of being overwritten by the next rainbow frame.
    func stopAllRGBCycles() {
        guard rgbCycleActive.values.contains(true) else { return }
        for key in rgbCycleActive.keys { rgbCycleActive[key] = false }
        rgbTimer?.invalidate(); rgbTimer = nil
        lastRGBColor = nil
    }


    private static func hsbToRGB(h: Float, s: Float, b: Float) -> (Float, Float, Float) {
        let c = b * s
        let x = c * (1 - abs(fmodf(h * 6, 2) - 1))
        let m = b - c
        let (r, g, bl): (Float, Float, Float)
        switch Int(h * 6) % 6 {
        case 0: (r, g, bl) = (c, x, 0)
        case 1: (r, g, bl) = (x, c, 0)
        case 2: (r, g, bl) = (0, c, x)
        case 3: (r, g, bl) = (0, x, c)
        case 4: (r, g, bl) = (x, 0, c)
        default: (r, g, bl) = (c, 0, x)
        }
        return (r + m, g + m, bl + m)
    }

    #if DEBUG
    /// Every preset colour this session tried to apply, for the readout.
    var debugTempLightLog: [String] = []
    #endif

    /// The colour the running preset asked for. While a preset is active
    /// this is the truth for every light-capable slot: a controller that
    /// connects or reconnects, a refresh, or a rainbow ending must all land
    /// on this, not on the slot's default colour. Without it the default
    /// (slot 0 is green) quietly replaced the preset's colour mid-session.
    private(set) var presetLightOverride: (r: Float, g: Float, b: Float, brightness: UInt8?)?

    /// Apply a preset's light colour to every light-capable slot and keep it
    /// as the override until the preset stops. Safe to call with no
    /// controller connected: the colour is applied when one arrives.
    func applyPresetLight(red: Float, green: Float, blue: Float, brightness: UInt8?) {
        presetLightOverride = (red, green, blue, brightness)
        stopAllRGBCycles()
        for slot in controllerDetails.keys where controllerDetails[slot]?.hasLight == true {
            applyTemporaryLight(at: slot, red: red, green: green, blue: blue, brightness: brightness)
        }
    }

    /// Slots currently showing a preset's temporary colour, so a stop can
    /// put back exactly those and leave a general rainbow cycle alone.
    private var temporaryLightSlots: Set<Int> = []

    /// Put every slot that was showing a temporary colour back on its
    /// stored general colour. Returns whether anything was reverted.
    @discardableResult
    func revertTemporaryLights() -> Bool {
        presetLightOverride = nil
        let slots = temporaryLightSlots
        temporaryLightSlots.removeAll()
        for slot in slots where slot < connectedControllers.count {
            setControllerLight(at: slot)
        }
        return !slots.isEmpty
    }

    /// Apply a light color WITHOUT storing it as the slot's default. Used by
    /// the mapping engine to flash a preset's chosen color while the preset
    /// is active; calling `setControllerLight(at:)` on stop restores the
    /// stored (user-default) color. Pass `brightness` to override the
    /// stored brightness for the duration; nil inherits.
    func applyTemporaryLight(at index: Int, red: Float, green: Float, blue: Float, brightness: UInt8? = nil) {
        guard index < connectedControllers.count else { return }
        #if DEBUG
        debugTempLightLog.append(String(format: "slot %d R%.0f G%.0f B%.0f", index, red * 255, green * 255, blue * 255))
        if debugTempLightLog.count > 40 { debugTempLightLog.removeFirst(debugTempLightLog.count - 40) }
        #endif
        temporaryLightSlots.insert(index)
        ActivityLog.shared.info("Light bar", String(format: "Preset colour on slot %d: R%.0f G%.0f B%.0f", index, red * 255, green * 255, blue * 255), slot: index)
        let bri = brightness ?? lightBrightness[index] ?? 2
        let scale: Float = switch bri {
        case 0: 0.0
        case 1: 0.25
        default: 1.0
        }
        let r = UInt8(min(max(red * scale * 255, 0), 255))
        let g = UInt8(min(max(green * scale * 255, 0), 255))
        let b = UInt8(min(max(blue * scale * 255, 0), 255))
        lastAppliedColor[index] = (r, g, b)
        applyAppleLight(at: index, red: r, green: g, blue: b)
        // HOLD the color, don't fire one shot. macOS's controller daemon owns
        // the DualSense light bar and repaints it on its own loop, so a single
        // write is overwritten within milliseconds and the user sees nothing
        // change when a preset with a light-bar override activates. The general
        // light path (applyLight) already holds for exactly this reason; the
        // per-preset override was the one path still doing a bare write.
        // stopHold happens on revert via setControllerLight, and when the last
        // controller disconnects.
        InProcessLightWriter.shared.startHold(red: r, green: g, blue: b)
    }

    /// Set the light through GameController's own light API as well as the
    /// raw report. This is the part that matters while a buzz is playing:
    /// macOS takes the controller's report stream to drive the haptics and
    /// repaints the light bar itself, and no raw re-assert is fast enough to
    /// win that. Told through its own API, it repaints our colour instead of
    /// its own. The raw write stays as the fallback for pads it does not
    /// cover, and paints the same colour, so the two cannot disagree.
    private func applyAppleLight(at index: Int, red: UInt8, green: UInt8, blue: UInt8) {
        // One writer per pad. When this app's own report writer owns a Sony
        // pad, the light is already in that report, and asking the system's
        // GCDeviceLight for the same colour hands the pad's output stream to
        // the system, whose writes carry zeroed motor fields and stomp a
        // rumble in progress. Measured on a DualSense Edge: the same motor
        // bytes felt strong with no preset running and weak with one, and
        // this call was the difference.
        if InProcessLightWriter.shared.ownsAnyDualSense { return }
        guard index < connectedControllers.count,
              let light = connectedControllers[index].light else { return }
        light.color = GCColor(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255)
    }

    /// Re-assert the colour a slot is meant to be showing. Called after a
    /// haptic, which is when the system is most likely to have repainted.
    func reassertLight(at index: Int) {
        guard let c = lastAppliedColor[index] else { return }
        applyAppleLight(at: index, red: c.0, green: c.1, blue: c.2)
        InProcessLightWriter.shared.startHold(red: c.0, green: c.1, blue: c.2)
    }

    /// Apply the light color in-process via the shared LED writer, scaling by
    /// brightness. (Previously spawned the LightHelper subprocess, which crashes
    /// with SIGTRAP under the sandbox + hardened runtime when the app launches
    /// it, so the LED never updated.)
    private func applyLight(at index: Int, red: Float, green: Float, blue: Float) {
        guard index < connectedControllers.count else { return }
        let brightness = lightBrightness[index] ?? 2
        let scale: Float = switch brightness {
        case 0: 0.0
        case 1: 0.25
        default: 1.0
        }
        let r = UInt8(min(max(red * scale * 255, 0), 255))
        let g = UInt8(min(max(green * scale * 255, 0), 255))
        let b = UInt8(min(max(blue * scale * 255, 0), 255))
        connectedControllers[index].playerIndex = .indexUnset
        lastAppliedColor[index] = (r, g, b)
        applyAppleLight(at: index, red: r, green: g, blue: b)
        // Hand the color to the high-rate hold writer, which hammers it onto the
        // LED from its own background queue. macOS 26's gamecontrollerd repaints
        // the LED on focus changes and on a loop while we're foreground, so a
        // single write loses (the color only appeared after clicking away, when
        // the daemon let go). Hammering overwrites the daemon within a few ms.
        InProcessLightWriter.shared.startHold(red: r, green: g, blue: b)
    }

    // MARK: - Motion re-zero

    /// Snapshot the controller's current motion reading as its resting
    /// zero, the same as the editor's Quick Zero, with a short pulse so the
    /// user knows it took. Returns false when the controller has no gyro.
    @discardableResult
    func rezeroMotion(slot: Int) -> Bool {
        guard slot < connectedControllers.count else { return false }
        let controller = connectedControllers[slot]
        guard let motion = controller.motion, motion.hasRotationRate else {
            ActivityLog.shared.warning("Motion", "Re-zero asked for slot \(slot) but it reports no gyroscope", slot: slot)
            return false
        }
        ActivityLog.shared.info("Motion", "Re-zeroed \(controller.vendorName ?? "controller") in slot \(slot)", slot: slot)
        let hasAccel = motion.hasGravityAndUserAcceleration
        // The gyro zero is only taken from a controller that is physically
        // still; a press mid-movement would store the movement as "rest"
        // and the pointer would creep until the next zero. When it is not
        // still, the pointer is still re-anchored (below, by the caller) and
        // drift learning takes the zero the next time it settles.
        if isPhysicallyStill(controller, motion: motion),
           let g = meanRawGyroRate(for: controller) {
            MotionCalibrationService.shared.quickZero(
                forKey: MotionCalibrationService.identityKey(for: controller),
                gyroX: g.x, gyroY: g.y, gyroZ: g.z,
                accelX: hasAccel ? Float(motion.userAcceleration.x) : 0,
                accelY: hasAccel ? Float(motion.userAcceleration.y) : 0,
                accelZ: hasAccel ? Float(motion.userAcceleration.z) : 0)
        } else {
            ActivityLog.shared.info("Motion", "Re-zero: controller was moving, keeping the stored zero and re-anchoring the pointer", slot: slot)
        }
        FeedbackService.shared.vibrate(controller: controller, intensity: 0.35)
        // A re-zero also snaps the fused pitch onto the accelerometer right
        // now and tells the visualizer to start its orientation from here.
        let acc = motion.acceleration
        for channel in [MotionChannel.gyroX, .gyroY] {
            let key = FusionKey(controller: ObjectIdentifier(controller), channel: channel)
            if var f = axisFusion[key] {
                f.estimate = f.sign * Self.accelAngle(channel, ax: Float(acc.x), ay: Float(acc.y), az: Float(acc.z))
                axisFusion[key] = f
            }
        }
        // Yaw has no reference to snap to: where the pad points now is zero.
        axisFusion[FusionKey(controller: ObjectIdentifier(controller), channel: .gyroZ)] = nil
        NotificationCenter.default.post(name: Self.motionRezeroedNotification, object: nil,
                                        userInfo: ["slot": slot])
        return true
    }

    // MARK: - Input Scanning

    func startScanning(completion: @escaping (InputEvent) -> Void) {
        isScanning = true
        scanCallback = completion

        // Set up value changed handlers on all connected controllers
        for (controllerIndex, controller) in connectedControllers.enumerated() {
            setupScanHandlers(for: controller, index: controllerIndex)
        }

        // Watch for motion deflection too - tilting the controller past
        // a threshold during scan fires InputEvent.motion so the user
        // can assign gyro tilts to outputs from the same Scan flow.
        motionScanTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMotionForScan() }
        }
        motionScanTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        // MIDI devices join the same Scan flow: press a key, twist a
        // knob, or move the bend wheel and it is captured like any
        // button. Opens the input port on demand so users who never
        // touch MIDI never pay for a CoreMIDI client.
        MIDIInputService.shared.startScanning { [weak self] event in
            Task { @MainActor in self?.scanCallback?(event) }
        }
        // Touchpad taps join Scan too, so a one-finger or two-finger tap on
        // the pad is captured as its own input, distinct from the press.
        TouchpadService.shared.scanGestureCallback = { [weak self] kind in
            Task { @MainActor in self?.scanCallback?(InputEvent.touchpadGesture(kind)) }
        }
    }

    func stopScanning() {
        isScanning = false
        scanCallback = nil
        MIDIInputService.shared.stopScanning()
        TouchpadService.shared.scanGestureCallback = nil
        motionScanTimer?.invalidate()
        motionScanTimer = nil
        motionScanFiredThisGesture = false
        // Remove the scan handlers, then immediately re-assert the live-input
        // handler so the poll keeps reading values after the editor closes.
        for controller in connectedControllers {
            removeScanHandlers(for: controller)
            installLiveInputHandler(for: controller)
            // Scan teardown wipes every element handler; the touchpad feed
            // lives on the pad's direction pads, so put it back explicitly.
            if let slot = connectedControllers.firstIndex(where: { $0 === controller }) {
                installTouchpadHandlers(for: controller, slot: slot)
            }
            // Scanning replaces the per-button handlers, which takes the
            // press logger with it; without this the live press log in
            // Settings, Devices stops recording after the first scan and
            // never comes back.
            pressLoggerWired.remove(ObjectIdentifier(controller))
            if let slot = connectedControllers.firstIndex(where: { $0 === controller }) {
                installPhysicalPressLogger(for: controller, slot: slot)
            }
        }
    }

    /// Timer that polls every connected controller's gyro rate during
    /// scan. Single-shot per gesture (latched in
    /// `motionScanFiredThisGesture`) so a sustained tilt doesn't spam
    /// the scan callback.
    private var motionScanTimer: Timer?
    private var motionScanFiredThisGesture: Bool = false
    /// rad/s threshold. ~1.5 is roughly a brisk tilt; lower triggers on
    /// noise, higher requires the user to whip the controller.
    private let motionScanThreshold: Float = 1.5

    private func checkMotionForScan() {
        guard isScanning, let cb = scanCallback else { return }

        // Find max-magnitude axis across all connected motion controllers.
        // Whichever axis crosses threshold first wins the scan.
        for controller in connectedControllers {
            guard let motion = controller.motion, motion.hasRotationRate else { continue }
            let key = MotionCalibrationService.identityKey(for: controller)
            let (gx, gy, gz) = MotionCalibrationService.shared.correctedGyro(
                x: Float(motion.rotationRate.x),
                y: Float(motion.rotationRate.y),
                z: Float(motion.rotationRate.z),
                forKey: key)

            let mag = max(abs(gx), abs(gy), abs(gz))
            // Latch: only fire once per gesture. Reset when rates drop
            // back below 25% of threshold so the user can re-tilt for a
            // second scan.
            if motionScanFiredThisGesture {
                if mag < motionScanThreshold * 0.25 {
                    motionScanFiredThisGesture = false
                }
                continue
            }
            guard mag >= motionScanThreshold else { continue }

            let event: InputEvent
            if abs(gx) >= abs(gy) && abs(gx) >= abs(gz) {
                event = .motion(.gyroX, direction: gx > 0 ? .positive : .negative)
            } else if abs(gy) >= abs(gz) {
                event = .motion(.gyroY, direction: gy > 0 ? .positive : .negative)
            } else {
                event = .motion(.gyroZ, direction: gz > 0 ? .positive : .negative)
            }
            motionScanFiredThisGesture = true
            cb(event)
            return
        }
    }

    /// Maps well-known physical profile button names to stable button indices.
    private static let knownButtonMap: [String: Int] = buildKnownButtonMap()

    /// Public mirror of `knownButtonMap` so views (e.g. Settings' controller
    /// diagnostic) can show which name maps to which button index.
    static let publicKnownButtonMap: [String: Int] = buildKnownButtonMap()

    private static func buildKnownButtonMap() -> [String: Int] {
        var m = [String: Int]()
        m["Button A"] = 0; m["Button B"] = 1; m["Button X"] = 2; m["Button Y"] = 3
        m["Left Shoulder"] = 4; m["Right Shoulder"] = 5
        m["Left Trigger"] = 6; m["Right Trigger"] = 7
        m["Button Options"] = 8; m["Button Menu"] = 9; m["Button Home"] = 10
        m["Left Thumbstick Button"] = 11; m["Right Thumbstick Button"] = 12
        m["Button Touchpad"] = 13; m["Touchpad Button"] = 13; m["Touchpad Primary Button"] = 13
        m["Button Share"] = 14; m["Button Capture"] = 14
        m["Create Button"] = 14; m["Share Button"] = 14
        m["Button Mute"] = 15; m["Microphone Button"] = 15; m["Mute Button"] = 15
        m["PS Button"] = 10; m["PlayStation Button"] = 10
        m["Left Paddle"] = 16; m["Right Paddle"] = 17
        m["Left Paddle Button"] = 16; m["Right Paddle Button"] = 17
        m["Button Paddle 1"] = 16; m["Button Paddle 2"] = 17
        m["Button Paddle 3"] = 18; m["Button Paddle 4"] = 19
        m["Paddle 1"] = 16; m["Paddle 2"] = 17; m["Paddle 3"] = 18; m["Paddle 4"] = 19
        // DualSense Edge function buttons (the two small buttons just below
        // each analog stick).
        m["Left Function Button"] = 20; m["Right Function Button"] = 21
        m["FN1 Button"] = 20; m["FN2 Button"] = 21
        m["FN1"] = 20; m["FN2"] = 21
        return m
    }

    /// Button names that are composites (D-pad, sticks), not individual buttons
    private static let ignoredProfileNames: [String] = [
        "Direction Pad", "Left Thumbstick", "Right Thumbstick",
        // The touchpad's finger positions arrive as direction pads whose
        // components are named "Touchpad 1 Up" and so on. They are finger
        // contact, read by TouchpadService, not buttons: mapping them to
        // index 13 made any touch look like the physical press and let a
        // later component zero a real press in the same poll.
        "Touchpad 1", "Touchpad 2"
    ]

    private func setupScanHandlers(for controller: GCController, index: Int) {
        guard let gamepad = controller.extendedGamepad else {
            setupPhysicalProfileScanHandlers(for: controller, index: index)
            return
        }

        // --- Standard extendedGamepad buttons ---
        let buttons: [(GCControllerButtonInput, Int)] = [
            (gamepad.buttonA, 0),
            (gamepad.buttonB, 1),
            (gamepad.buttonX, 2),
            (gamepad.buttonY, 3),
            (gamepad.leftShoulder, 4),
            (gamepad.rightShoulder, 5),
            (gamepad.leftTrigger, 6),
            (gamepad.rightTrigger, 7),
        ]

        var allMappedButtons: [(GCControllerButtonInput, Int)] = buttons

        if let options = gamepad.buttonOptions { allMappedButtons.append((options, 8)) }
        if let menu = gamepad.buttonMenu as GCControllerButtonInput? { allMappedButtons.append((menu, 9)) }
        if let home = gamepad.buttonHome { allMappedButtons.append((home, 10)) }
        if let l3 = gamepad.leftThumbstickButton { allMappedButtons.append((l3, 11)) }
        if let r3 = gamepad.rightThumbstickButton { allMappedButtons.append((r3, 12)) }

        // Diagnostic: log which typed buttons we successfully wired up.
        // If buttonHome is missing from this list, gamepad.buttonHome
        // returned nil on this controller and the PS press won't fire
        // our typed handler at all - we'd have to fall through to the
        // physical-profile scan handler instead.
        NSLog("[GCS] setupScanHandlers wired %d typed buttons on slot %d (controller=%@, hasHome=%@, hasOptions=%@, hasMenu=%@)",
              allMappedButtons.count, index,
              controller.vendorName ?? "?",
              gamepad.buttonHome != nil ? "YES" : "no",
              gamepad.buttonOptions != nil ? "YES" : "no",
              gamepad.buttonMenu as GCControllerButtonInput? != nil ? "YES" : "no")

        for (button, btnIndex) in allMappedButtons {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        // Loud diagnostic so we can see if the typed-handler
                        // path is actually firing for PS / Home / Mute /
                        // paddle presses. Visible via `log stream` in
                        // Terminal so the user can confirm presses reach us.
                        NSLog("[GCS] SCAN typed btn fired: slot=%d index=%d", index, btnIndex)
                        let event = InputEvent.button(btnIndex)
                        self?.scanCallback?(event)
                    }
                }
            }
        }

        // --- Extra physical profile buttons (touchpad click, share, mute,
        //     paddles, DualSense Edge FN buttons, etc.) ---
        // Use the EXACT same mapping that `readControllerState` will use to
        // read state every frame. Previously the scan path and the read
        // path each built their own dynamic-index mapping; if they
        // disagreed for any unknown name (very common on DualSense Edge),
        // scanning would record one button index and the engine would
        // never see it pressed under that index again.
        let alreadyHandled = Set(allMappedButtons.map { ObjectIdentifier($0.0) })
        let cached = cachedExtraButtons[index] ?? []
        for (button, btnIndex) in cached where !alreadyHandled.contains(ObjectIdentifier(button)) {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        let event = InputEvent.button(btnIndex)
                        self?.scanCallback?(event)
                    }
                }
            }
        }

        #if DEBUG
        let names = Array(controller.physicalInputProfile.buttons.keys).sorted()
        print("[GCS] Physical profile buttons for \(controller.vendorName ?? "?"): \(names)")
        print("[GCS] Cached extras (button -> index):")
        for (_, btnIndex) in cached {
            print("[GCS]   -> btn \(btnIndex)")
        }
        #endif

        // --- Extra analogue inputs from an accessory ---
        // An extra trigger, pedal, or proportional stick plugged into an
        // adaptive controller reads like any other axis, so Scan captures
        // it the same way: push it past halfway and the row is bound.
        for (axis, axisIndex, _) in cachedExtraAxes[index] ?? [] {
            axis.valueChangedHandler = { [weak self] _, value in
                guard abs(value) > 0.5 else { return }
                Task { @MainActor in
                    self?.scanCallback?(InputEvent.axis(axisIndex,
                                                        direction: value > 0 ? .positive : .negative))
                }
            }
        }

        // --- D-pad ---
        gamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                var event: InputEvent?
                if yValue > 0.5 { event = InputEvent.hat(0, direction: .up) }
                else if yValue < -0.5 { event = InputEvent.hat(0, direction: .down) }
                else if xValue < -0.5 { event = InputEvent.hat(0, direction: .left) }
                else if xValue > 0.5 { event = InputEvent.hat(0, direction: .right) }

                if let event = event {
                    self?.scanCallback?(event)
                }
            }
        }

        // --- Sticks ---
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                if abs(xValue) > 0.5 {
                    let event = InputEvent.axis(0, direction: xValue > 0 ? .positive : .negative)
                    self?.scanCallback?(event)
                }
                if abs(yValue) > 0.5 {
                    let event = InputEvent.axis(1, direction: yValue > 0 ? .negative : .positive)
                    self?.scanCallback?(event)
                }
            }
        }

        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                if abs(xValue) > 0.5 {
                    let event = InputEvent.axis(2, direction: xValue > 0 ? .positive : .negative)
                    self?.scanCallback?(event)
                }
                if abs(yValue) > 0.5 {
                    let event = InputEvent.axis(3, direction: yValue > 0 ? .negative : .positive)
                    self?.scanCallback?(event)
                }
            }
        }

        // --- Trigger analog axes ---
        gamepad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            if value > 0.5 {
                Task { @MainActor in
                    let event = InputEvent.axis(4, direction: .positive)
                    self?.scanCallback?(event)
                }
            }
        }

        gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            if value > 0.5 {
                Task { @MainActor in
                    let event = InputEvent.axis(5, direction: .positive)
                    self?.scanCallback?(event)
                }
            }
        }
    }

    private func setupPhysicalProfileScanHandlers(for controller: GCController, index: Int) {
        let profile = controller.physicalInputProfile

        for (name, button) in profile.buttons {
            if Self.ignoredProfileNames.contains(where: { name.contains($0) }) { continue }
            // Capture the button's ObjectIdentifier outside the Task -
            // it's a Sendable value (just a pointer wrapper) where the
            // class reference itself is not Sendable and can't cross
            // the @MainActor boundary under strict concurrency.
            let buttonID = ObjectIdentifier(button)
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        guard let self = self else { return }
                        // Resolve the right index for this button.
                        //
                        // 1) Prefer the cached extras lookup - it was built
                        //    on connect via KVC, so it has the correct
                        //    index for DualSense Edge paddles ("Left Paddle"
                        //    → 16, "Right Paddle" → 17, "Mute"/microphone →
                        //    15, FN buttons → 20/21) and for special MFi
                        //    names like "Touchpad Button"/"Share Button"
                        //    that don't embed a digit in their name.
                        // 2) Fall back to the static knownButtonMap for
                        //    common synthetic names.
                        // 3) As a last resort use extractButtonIndex which
                        //    only works when the name happens to embed a
                        //    digit ("Button 5"). This used to be the only
                        //    path, which silently mapped every extra
                        //    button to slot 0 (= A button) during scan -
                        //    the user complained that paddle/FN/Home/mute
                        //    presses were "not detected" when in fact they
                        //    were detected but mapped to the wrong slot.
                        let btnIndex: Int
                        if let cached = self.cachedExtraButtons[index]?
                            .first(where: { ObjectIdentifier($0.0) == buttonID }) {
                            btnIndex = cached.1
                        } else if let known = Self.knownButtonMap[name] {
                            btnIndex = known
                        } else {
                            btnIndex = self.extractButtonIndex(from: name)
                        }
                        let event = InputEvent.button(btnIndex)
                        self.scanCallback?(event)
                    }
                }
            }
        }

        for (name, axis) in profile.axes {
            axis.valueChangedHandler = { [weak self] _, value in
                if abs(value) > 0.5 {
                    Task { @MainActor in
                        let axisIndex = self?.extractAxisIndex(from: name) ?? 0
                        let event = InputEvent.axis(axisIndex, direction: value > 0 ? .positive : .negative)
                        self?.scanCallback?(event)
                    }
                }
            }
        }
    }

    private func removeScanHandlers(for controller: GCController) {
        // Clear all extendedGamepad handlers
        if let gamepad = controller.extendedGamepad {
            gamepad.buttonA.pressedChangedHandler = nil
            gamepad.buttonB.pressedChangedHandler = nil
            gamepad.buttonX.pressedChangedHandler = nil
            gamepad.buttonY.pressedChangedHandler = nil
            gamepad.leftShoulder.pressedChangedHandler = nil
            gamepad.rightShoulder.pressedChangedHandler = nil
            gamepad.leftTrigger.pressedChangedHandler = nil
            gamepad.leftTrigger.valueChangedHandler = nil
            gamepad.rightTrigger.pressedChangedHandler = nil
            gamepad.rightTrigger.valueChangedHandler = nil
            gamepad.dpad.valueChangedHandler = nil
            gamepad.leftThumbstick.valueChangedHandler = nil
            gamepad.rightThumbstick.valueChangedHandler = nil
            gamepad.buttonOptions?.pressedChangedHandler = nil
            (gamepad.buttonMenu as GCControllerButtonInput?)?.pressedChangedHandler = nil
            gamepad.buttonHome?.pressedChangedHandler = nil
            gamepad.leftThumbstickButton?.pressedChangedHandler = nil
            gamepad.rightThumbstickButton?.pressedChangedHandler = nil
        }

        // Clear ALL physical profile handlers (covers every button/axis including
        // touchpad, mute, share, paddles, adaptive controller buttons, etc.)
        for (_, button) in controller.physicalInputProfile.buttons {
            button.pressedChangedHandler = nil
            button.valueChangedHandler = nil
        }
        for (_, axis) in controller.physicalInputProfile.axes {
            axis.valueChangedHandler = nil
        }
    }

    /// Keep a controller's input stream active during normal (non-scan)
    /// operation. On macOS 26 the GameController framework only refreshes a
    /// profile's pollable `.value`s while a handler is attached to it. The app
    /// reads state by polling (`readControllerState`) every frame, so with no
    /// handler installed every poll returns zero, and the live visualizer, the
    /// mapping engine, and the connect-time light all see a dead controller.
    /// Installing a profile-level handler keeps the values live. It is
    /// deliberately a no-op: the 30 Hz poll does the actual reading. The scan
    /// path installs its own per-element handlers on top and clears them on
    /// exit; this profile-level handler is independent and survives that.
    private func installLiveInputHandler(for controller: GCController) {
        if let pad = controller.extendedGamepad {
            pad.valueChangedHandler = { _, _ in }
        } else {
            // Profile-only devices (solo Joy-Con orientations, remote-class or
            // adaptive hardware) need per-element no-op handlers for the same
            // macOS 26 keep-values-fresh reason. Without this, the first scan's
            // teardown left them permanently reading zeros until replug.
            let profile = controller.physicalInputProfile
            for (_, button) in profile.buttons {
                button.valueChangedHandler = { _, _, _ in }
            }
            for (_, axis) in profile.axes {
                axis.valueChangedHandler = { _, _ in }
            }
            for (_, dpad) in profile.dpads {
                dpad.valueChangedHandler = { _, _, _ in }
            }
        }
    }

    // MARK: - Polling (for mapping engine)

    func readControllerState(at index: Int) -> ControllerState? {
        #if DEBUG
        // Marketing capture: drive the sticks and triggers along a slow sweep
        // so calibration plots draw a full trail and the live readouts show
        // real numbers instead of a dead 0%. Never compiled into Release.
        if marketingFakeActive, index <= 1 {
            let t = CACurrentMediaTime()
            var st = ControllerState()
            st.axes[0] = Float(cos(t * 2.1)) * 0.93
            st.axes[1] = Float(sin(t * 2.1)) * 0.93
            st.axes[2] = Float(cos(t * 1.6)) * 0.72
            st.axes[3] = Float(sin(t * 1.6)) * 0.72
            st.axes[4] = Float((sin(t * 1.15) + 1) / 2)
            st.axes[5] = Float((cos(t * 0.95) + 1) / 2)
            if marketingFakePress {
                // Photographed "in use": right trigger pulled, Cross and R1
                // down, left stick pushed up-right.
                st.axes[5] = 0.85
                st.buttons[0] = 1.0
                st.buttons[5] = 1.0
                st.axes[0] = 0.62; st.axes[1] = -0.7
            }
            return st
        }
        #endif
        // Steam Controllers occupy the virtual slot just past the last
        // MFi controller. When a binding targets that slot we ask the
        // SteamControllerService for its synthesized ControllerState.
        if let steamIndex = steamControllerSlot, index == steamIndex {
            return SteamControllerService.shared.makeControllerState()
        }
        // A real MFi controller at this slot always takes precedence over a
        // raw-HID entry at the same index, so a hot-plugged MFi controller can
        // never be shadowed by a raw-HID pad that was assigned a low slot while
        // no MFi controller was present. Slots at or past the MFi count belong
        // to Steam (handled above) or to raw-HID gamepads, whose state comes
        // from the lock-protected snapshot the HID report callback wrote.
        guard index < connectedControllers.count else {
            if let gamepad = rawHIDGamepadSlots[index] {
                return gamepad.state
            }
            return nil
        }
        let controller = connectedControllers[index]

        var state = ControllerState()

        if let gamepad = controller.extendedGamepad {
            // --- Standard extendedGamepad buttons (0-12) ---
            state.buttons[0] = gamepad.buttonA.value
            state.buttons[1] = gamepad.buttonB.value
            state.buttons[2] = gamepad.buttonX.value
            state.buttons[3] = gamepad.buttonY.value
            state.buttons[4] = gamepad.leftShoulder.value
            state.buttons[5] = gamepad.rightShoulder.value
            state.buttons[6] = gamepad.leftTrigger.value
            state.buttons[7] = gamepad.rightTrigger.value

            if let options = gamepad.buttonOptions { state.buttons[8] = options.value }
            if let menu = gamepad.buttonMenu as GCControllerButtonInput? { state.buttons[9] = menu.value }
            if let home = gamepad.buttonHome { state.buttons[10] = home.value }
            if let l3 = gamepad.leftThumbstickButton { state.buttons[11] = l3.value }
            if let r3 = gamepad.rightThumbstickButton { state.buttons[12] = r3.value }

            // --- Extra physical profile buttons (touchpad, mute, share, paddles, etc.) ---
            // Uses pre-cached mapping built on connection so no sorting or matching at 120Hz
            if let extras = cachedExtraButtons[index] {
                for (button, btnIndex) in extras {
                    state.buttons[btnIndex] = button.value
                    // Tell the tap detector when the pad is physically
                    // pressed, so a click is never also reported as a tap.
                    if btnIndex == 13 { TouchpadService.shared.setTouchpadButtonPressed(button.value > 0.5) }
                }
            }

            // --- DualSense Edge supplemental buttons ---
            // Apple's GameController framework doesn't expose the
            // Edge's paddles, FN1/FN2, or microphone-mute. We read
            // them directly via IOHIDManager in
            // `DualSenseSupplementService` and merge the result here
            // so existing bindings against indices 15/16/17/20/21
            // light up the same way native MFi buttons do. Skipped
            // for non-DualSense slots (the dictionary is empty for
            // those, so the loop is a no-op).
            if dualSenseSlots.contains(index) {
                let supplement = DualSenseSupplementService.shared.anySupplementalButtons()
                for (btnIndex, value) in supplement where value > 0.5 {
                    state.buttons[btnIndex] = value
                }
            }

            // --- Axes ---
            state.axes[0] = gamepad.leftThumbstick.xAxis.value
            state.axes[1] = -gamepad.leftThumbstick.yAxis.value
            state.axes[2] = gamepad.rightThumbstick.xAxis.value
            state.axes[3] = -gamepad.rightThumbstick.yAxis.value
            state.axes[4] = gamepad.leftTrigger.value
            state.axes[5] = gamepad.rightTrigger.value

            // Analogue inputs from an accessory (an extra trigger, a pedal,
            // a proportional stick on an adaptive controller) sit past the
            // standard six and are read the same way.
            if let extras = cachedExtraAxes[index] {
                for (axis, axisIndex, _) in extras {
                    state.axes[axisIndex] = axis.value
                }
            }

            // --- Hat (D-pad) ---
            state.hats[0] = (gamepad.dpad.xAxis.value, gamepad.dpad.yAxis.value)

            // --- Motion sensors (gyro + accel + attitude) ---
            // Populated only when the controller actually exposes motion.
            // Bindings of type `.motion` consume these via MappingEngine.
            // Drift correction: subtract the per-controller calibration
            // baseline (zero gyro/accel at rest) so a still controller
            // reads exactly 0 on every motion channel.
            if let motion = controller.motion {
                let key = MotionCalibrationService.identityKey(for: controller)
                // Guard the accel read like the gyro block below: a controller
                // that exposes motion but not gravity/user-acceleration returns
                // undefined values here, which would feed NaN/garbage into the
                // calibration and motion bindings.
                if motion.hasGravityAndUserAcceleration {
                    let (ax, ay, az) = MotionCalibrationService.shared.correctedAccel(
                        x: Float(motion.userAcceleration.x),
                        y: Float(motion.userAcceleration.y),
                        z: Float(motion.userAcceleration.z),
                        forKey: key)
                    state.motion[.accelX] = ax
                    state.motion[.accelY] = ay
                    state.motion[.accelZ] = az
                }
                if motion.hasRotationRate {
                    // The angle actually turned since the last poll (every
                    // sensor sample counted) is the truth; the rate is its
                    // average over the interval. See `GyroAccumulator`.
                    let drained = drainGyro(for: controller)
                    let rate = drained.angle.map { $0 / drained.interval }
                        ?? SIMD3(Float(motion.rotationRate.x), Float(motion.rotationRate.y), Float(motion.rotationRate.z))
                    let (gx, gy, gz) = MotionCalibrationService.shared.correctedGyro(
                        x: rate.x, y: rate.y, z: rate.z,
                        forKey: key)
                    state.motion[.gyroX] = gx
                    state.motion[.gyroY] = gy
                    state.motionAngle[.gyroX] = gx * drained.interval
                    state.motionAngle[.gyroY] = gy * drained.interval
                    // Gyro Z is "turn left or right": the rotation about
                    // gravity, whatever way the pad is held, positive when
                    // pointing right. Pointing a controller left and right is
                    // a yaw, not a roll; a pointer driven from roll (gyro Y)
                    // only saw the small sideways tilt that comes with it,
                    // which is why left and right lagged behind up and down.
                    // Measured about gravity rather than the pad's own Z so
                    // a pad held nose-up still turns the pointer sideways.
                    let yawRate = worldYawRate(gx: gx, gy: gy, gz: gz, motion: motion) ?? gz
                    state.motion[.gyroZ] = yawRate
                    state.motionAngle[.gyroZ] = yawRate * drained.interval
                    // No gravity reference for yaw, so its absolute is the
                    // integrated turn since the last re-zero; the learned
                    // gyro zero keeps it from creeping.
                    let yawKey = FusionKey(controller: ObjectIdentifier(controller), channel: .gyroZ)
                    var yaw = axisFusion[yawKey] ?? AxisFusion()
                    yaw.estimate += yawRate * drained.interval
                    axisFusion[yawKey] = yaw
                    state.motionAbsolute[.gyroZ] = yaw.estimate
                    state.motionCorrection[.gyroZ] = 0
                    // Pitch gets the accelerometer anchor; the pointer path
                    // reads the fused change, so a slam the gyro could not
                    // follow still ends with the pointer where "flat" was.
                    let corrected = SIMD3(gx, gy, gz)
                    if let fused = fuseTilt(.gyroX, controller: controller, motion: motion,
                                            gyroRate: gx, interval: drained.interval, corrected: corrected) {
                        state.motionAngle[.gyroX] = fused.gyro
                        state.motionCorrection[.gyroX] = fused.correction
                        state.motionAbsolute[.gyroX] = fused.absolute
                        if !motion.hasAttitude { state.motion[.pitchAngle] = fused.absolute / (.pi / 2) }
                    }
                    if let fused = fuseTilt(.gyroY, controller: controller, motion: motion,
                                            gyroRate: gy, interval: drained.interval, corrected: corrected) {
                        state.motionAngle[.gyroY] = fused.gyro
                        state.motionCorrection[.gyroY] = fused.correction
                        state.motionAbsolute[.gyroY] = fused.absolute
                        if !motion.hasAttitude { state.motion[.rollAngle] = fused.absolute / .pi }
                    }
                    learnGyroDrift(controller: controller, motion: motion, corrected: SIMD3(gx, gy, gz),
                                   interval: drained.interval, key: key)
                }
                if motion.hasAttitude {
                    // Convert quaternion (x,y,z,w) to Euler roll/pitch/yaw.
                    // The output is in radians; downstream code normalizes
                    // by dividing by π to land in roughly [-1, 1].
                    let q = motion.attitude
                    let qx = Float(q.x), qy = Float(q.y), qz = Float(q.z), qw = Float(q.w)
                    let roll  = atan2(2 * (qw * qx + qy * qz),
                                      1 - 2 * (qx * qx + qy * qy))
                    let pitchArg = 2 * (qw * qy - qz * qx)
                    let pitch = asin(max(-1.0, min(1.0, pitchArg)))
                    let yaw   = atan2(2 * (qw * qz + qx * qy),
                                      1 - 2 * (qy * qy + qz * qz))
                    state.motion[.rollAngle]  = roll  / .pi   // ≈ -1...1
                    state.motion[.pitchAngle] = pitch / (.pi / 2)
                    state.motion[.yawAngle]   = yaw   / .pi
                }
            }
        } else {
            // Physical input profile fallback for non-standard controllers.
            // CRITICAL: resolve names with the SAME chain the scan path uses
            // (knownButtonMap first, digit extraction as last resort). The old
            // digit-only fallback mapped every letter-named button ("Button B")
            // to index 0, so anything scanned on these devices could never
            // fire at runtime.
            let profile = controller.physicalInputProfile
            if let cached = cachedExtraButtons[index], !cached.isEmpty {
                // Same indices Scan and the layout use (see cacheExtraButtons).
                for (button, idx) in cached { state.buttons[idx] = button.value }
            } else {
                for (name, button) in profile.buttons {
                    let idx = Self.knownButtonMap[name] ?? extractButtonIndex(from: name)
                    state.buttons[idx] = button.value
                }
            }
            for (name, axis) in profile.axes {
                let idx = extractAxisIndex(from: name)
                state.axes[idx] = axis.value
            }
            // D-pads were previously ignored here entirely, leaving hats dead
            // on profile-only devices. GCControllerDirectionPad's yAxis is
            // already up-positive (the app's hat convention).
            for (hatIdx, entry) in profile.dpads.sorted(by: { $0.key < $1.key }).enumerated() {
                state.hats[hatIdx] = (x: entry.value.xAxis.value, y: entry.value.yAxis.value)
            }
        }

        return state
    }

    // MARK: - Helpers

    /// Slots whose controller is a DualSense / DualSense Edge, computed once
    /// per connection in `cacheExtraButtons`. Read every poll frame by
    /// `readControllerState` for the supplement merge.
    private var dualSenseSlots: Set<Int> = []

    /// Controllers whose press logger is already installed. Without this,
    /// every `refreshControllers()` (one per hotplug event) re-wrapped each
    /// button's handler in one more pass-through closure, growing the handler
    /// chain without bound.
    private var pressLoggerWired: Set<ObjectIdentifier> = []

    // MARK: - Physical press diagnostic log

    /// Install a pass-through press logger on every button in the
    /// physical input profile. Fires alongside (NOT instead of) the
    /// scan / read handlers so we can show the user EXACTLY which name
    /// Apple's framework reports for the button they just pressed. The
    /// Settings > Controllers diagnostic surfaces this list.
    private func installPhysicalPressLogger(for controller: GCController, slot: Int) {
        // Idempotent: refreshControllers runs on every hotplug, and wiring a
        // second time would re-wrap each prior handler in another pass-through
        // closure, growing the chain (and per-press cost) without bound. The
        // closure resolves the slot at fire time so the log stays correct when
        // slots reshuffle after another controller disconnects.
        let identity = ObjectIdentifier(controller)
        guard !pressLoggerWired.contains(identity) else { return }
        pressLoggerWired.insert(identity)
        let profile = controller.physicalInputProfile
        // macOS eats the Home / PS / Guide button as a system gesture, so an
        // app never sees it: Scan waits forever and no binding on it can
        // fire. Asking for the gesture to be disabled hands the press to us
        // instead. Done for every button that offers the setting, because
        // the Share / Create button is treated the same way on some
        // controllers, and the emergency-stop hold needs its button to
        // arrive whatever the system would rather do with it.
        for (name, button) in profile.buttons
        where name.contains("Home") || name.contains("PS") || name.contains("Guide") {
            button.preferredSystemGestureState = .disabled
        }
        for (name, button) in profile.buttons {
            // Skip the composite "Direction Pad", thumbsticks, etc.
            if Self.ignoredProfileNames.contains(where: { name.contains($0) }) { continue }
            // Capture any prior handler (set by setupScanHandlers or our
            // cache loop) so we can call it after logging.
            let prior = button.pressedChangedHandler
            let mappedIndex = Self.knownButtonMap[name]
                ?? (cachedExtraButtons[slot]?.first(where: { ObjectIdentifier($0.0) == ObjectIdentifier(button) })?.1)
            button.pressedChangedHandler = { [weak self, weak controller] btn, value, pressed in
                if pressed {
                    Task { @MainActor in
                        guard let self else { return }
                        let liveSlot = controller.flatMap { c in
                            self.connectedControllers.firstIndex(where: { $0 === c })
                        } ?? slot
                        self.logPhysicalPress(name: name, slot: liveSlot, mappedIndex: mappedIndex)
                    }
                }
                prior?(btn, value, pressed)
            }
        }
    }

    private func logPhysicalPress(name: String, slot: Int, mappedIndex: Int?) {
        PhysicalPressLogStore.shared.log(slot: slot, name: name, mappedIndex: mappedIndex)
    }

    // MARK: - Raw active inputs (drives editor highlight without a running preset)

    /// Threshold for considering an analog axis "active". Matches the engine's
    /// defaultAxisThreshold so highlight and binding fire feel the same.
    private let rawActiveAxisThreshold: Float = 0.5
    private let rawActiveHatThreshold: Float = 0.5

    /// Minimum time a detected input stays in `rawActiveInputs` after we
    /// last saw it pressed. Even a single-frame tap (which a slow polling
    /// loop would miss entirely) lingers long enough to be visible as the
    /// green row highlight in the editor.
    private let rawActiveLingerSeconds: TimeInterval = 0.20

    /// Per-input expiry timestamps. We keep an entry in `rawActiveInputs`
    /// as long as its expiry is in the future.
    private var rawActiveExpiry: [String: Date] = [:]

    private func startRawActiveInputsPolling() {
        // 30 Hz polling - catches quick taps a 10 Hz loop would miss. Cheap
        // because we only read controller state and update a Set.
        rawActivePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // The timer fires on RunLoop.main (main thread = main actor), so run
            // inline instead of spawning a Task per tick (an allocation + hop
            // 30x/second). The fast-path guard inside then runs with zero cost.
            MainActor.assumeIsolated {
                self?.refreshRawActiveInputs()
            }
        }
        if let t = rawActivePollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// Snapshot every connected controller's current state and turn pressed
    /// buttons / deflected axes / hat directions into the serialized strings
    /// the editor uses to match binding rows. Each detected input gets a
    /// 200 ms expiry so quick taps remain visible.
    /// Who is reading the 30 Hz snapshot right now: the editor, the
    /// visualizer, the motion calibrator, or the running engine (which
    /// needs the touchpad feed this loop provides for pads macOS does not
    /// give a typed Sony class). With none of them, and no scan, the loop
    /// does nothing at all, so an idle app with a controller plugged in
    /// costs nothing. It was doing the full read thirty times a second
    /// for as long as any controller was connected.
    private var liveConsumers: Set<String> = []
    func retainLiveInput(_ reason: String) { liveConsumers.insert(reason) }
    var debugLiveConsumers: [String] { liveConsumers.sorted() }
    func releaseLiveInput(_ reason: String) { liveConsumers.remove(reason) }

    private func refreshRawActiveInputs() {
        // Nobody reading: clear whatever derived state is left once, so no
        // stale highlight or snapshot survives, then do nothing.
        if liveConsumers.isEmpty, !isScanning {
            if !rawActiveExpiry.isEmpty || !rawActiveInputs.isEmpty || !currentStates.isEmpty {
                rawActiveExpiry.removeAll()
                rawActiveInputs = []
                currentStates = [:]
            }
            return
        }
        // Fast path: when no input source is connected and there is no
        // lingering highlight state or visualizer snapshot left to clear,
        // there is nothing to read or update. Skipping the whole body means
        // the 30 Hz timer costs effectively nothing on the welcome screen or
        // any time every controller is unplugged. The guard is conservative:
        // it only returns when a scan is not running and every piece of
        // derived state is already empty, so no stale highlight or snapshot
        // can be left behind.
        if connectedControllers.isEmpty,
           steamControllerSlot == nil,
           rawHIDGamepadSlots.isEmpty,
           !isScanning,
           rawActiveExpiry.isEmpty,
           rawActiveInputs.isEmpty,
           currentStates.isEmpty {
            return
        }

        // Reuse mutable scratch containers across ticks. Previously this
        // method allocated fresh Set<String> and [Int: ControllerState]
        // every 30 Hz frame, generating ~60 collection allocations per
        // second just for the editor highlight bookkeeping.
        scratchFreshlyActive.removeAll(keepingCapacity: true)
        scratchSnapshots.removeAll(keepingCapacity: true)

        // Real MFi controllers
        for i in connectedControllers.indices {
            guard let state = readControllerState(at: i) else { continue }
            scratchSnapshots[i] = state
            accumulate(into: &scratchFreshlyActive, state: state)
            // Bridge any DualSense / DualShock 4 touchpad data the
            // GameController framework reports through to the touchpad
            // pipeline (see notes in feedTouchpadFromController).
            feedTouchpadFromController(connectedControllers[i], slot: i)
        }
        // Steam Controller virtual slot
        if let slot = steamControllerSlot, let state = readControllerState(at: slot) {
            scratchSnapshots[slot] = state
            accumulate(into: &scratchFreshlyActive, state: state)
        }
        // Raw HID gamepads (8BitDo XInput, Xbox 360 wired, etc.)
        for (slot, _) in rawHIDGamepadSlots {
            guard let state = readControllerState(at: slot) else { continue }
            scratchSnapshots[slot] = state
            accumulate(into: &scratchFreshlyActive, state: state)
        }
        // A controller's re-zero button (chosen in the Motion Calibration
        // sheet) works with no preset running: a fresh press snapshots that
        // controller's resting zero. Rising edge against the previous tick.
        for i in connectedControllers.indices {
            guard let state = scratchSnapshots[i],
                  let btn = MotionCalibrationService.shared.rezeroButton(
                      forKey: MotionCalibrationService.identityKey(for: connectedControllers[i])),
                  (state.buttons[btn] ?? 0) > 0.5,
                  (currentStates[i]?.buttons[btn] ?? 0) <= 0.5 else { continue }
            rezeroMotion(slot: i)
        }

        // Regions are inputs too, and the editor lights a row from this
        // same set. Without these, touching a zone on the pad lit it in
        // the visualizer (which reads the services directly) while the
        // row for that zone sat dark, which read as the zone not working.
        accumulateRegions(into: &scratchFreshlyActive)

        // ControllerState isn't Equatable (its hat tuples can't auto-
        // derive it), so we always assign. Cost is negligible for 1-2
        // controllers at 30 Hz; copy is a single shallow Dict copy.
        currentStates = scratchSnapshots

        // Bridge supplemental inputs into the scan flow. Some buttons -
        // notably the PS / Home button on DualSense under macOS 26's
        // Game Mode - are swallowed by Apple's framework before our
        // typed pressedChangedHandlers fire. Our raw HID supplement
        // still sees those presses and merges them into state.buttons;
        // we detect a 0→1 transition here and fire the scanCallback so
        // the binding editor's Scan button can still capture them.
        if isScanning, let cb = scanCallback {
            // Find a freshly-active input that wasn't active last tick.
            // Avoid `Set.subtracting`'s new-Set allocation by looping.
            var firedKey: String?
            for key in scratchFreshlyActive where !rawActiveInputs.contains(key) {
                firedKey = key
                break
            }
            if let first = firedKey, let event = InputEvent.parse(first) {
                cb(event)
            }
        }

        // Stamp expiry timestamps for everything currently pressed.
        let now = Date()
        let expiryDate = now.addingTimeInterval(rawActiveLingerSeconds)
        for key in scratchFreshlyActive {
            rawActiveExpiry[key] = expiryDate
        }
        // Drop entries whose expiry has passed. Collect into a reused scratch
        // array (not a fresh `Array(rawActiveExpiry.keys)` every 30 Hz tick) to
        // avoid mutating-during-iteration UB with zero per-tick allocation.
        scratchExpiredKeys.removeAll(keepingCapacity: true)
        for (key, date) in rawActiveExpiry where date <= now {
            scratchExpiredKeys.append(key)
        }
        for key in scratchExpiredKeys {
            rawActiveExpiry.removeValue(forKey: key)
        }
        // Build the published Set only when the membership actually
        // changed. Skip the equality check on the common steady-state
        // tick where no new keys were added or expired.
        if rawActiveExpiry.count != rawActiveInputs.count
            || !rawActiveInputs.isSuperset(of: rawActiveExpiry.keys) {
            rawActiveInputs = Set(rawActiveExpiry.keys)
        }
    }

    /// Scratch containers reused by `refreshRawActiveInputs` so the
    /// 30 Hz loop doesn't allocate fresh collections on every tick.
    /// Sit at the type level next to other state so they're not
    /// re-allocated on every call.
    private var scratchFreshlyActive: Set<String> = []
    /// Reused across 30 Hz ticks to collect expired raw-active keys without a
    /// fresh Array allocation per tick.
    private var scratchExpiredKeys: [String] = []
    private var scratchSnapshots: [Int: ControllerState] = [:]

    /// Read touchpad finger positions from a `GCDualSenseGamepad` or
    /// `GCDualShockGamepad` profile and push them into TouchpadService.
    /// No-op for any controller that doesn't expose a touchpad.
    ///
    /// macOS 14+ exposes the DualSense / DS4 touchpad through
    /// `touchpadPrimary` / `touchpadSecondary` direction pads on the
    /// typed extendedGamepad subclass. Reading them this way works
    /// even when `gamecontrollerd` has the device open exclusively
    /// and our TouchpadHelper subprocess sees zero bytes.
    ///
    /// Slot is accepted for symmetry but not used yet; TouchpadService
    /// is single-instance and tracks one device's worth of state. If
    /// we ever support two touchpads simultaneously, we route by slot.
    /// Wire `valueChangedHandler` on a controller's touchpad direction
    /// pads so finger motion is pushed into TouchpadService at the
    /// controller's native HID rate (≈1000 Hz USB DualSense, ≈250 Hz
    /// Bluetooth) instead of the 30 Hz `refreshRawActiveInputs` poll.
    ///
    /// The 30 Hz poll path stays as a fallback for controllers that
    /// don't take the typed-subclass branch here (generic dpads scan in
    /// `feedTouchpadFromController`). Dual writes are safe because
    /// TouchpadService.ingestGameControllerTouchpad locks the underlying
    /// state and the latest write wins.
    #if DEBUG
    /// What the touchpad handler install saw, per slot, for the debug readout.
    var debugTouchpadInstall: [Int: String] = [:]
    #endif

    private func installTouchpadHandlers(for controller: GCController, slot: Int) {
        guard let pad = controller.extendedGamepad else {
            #if DEBUG
            debugTouchpadInstall[slot] = "no extendedGamepad"
            #endif
            return
        }

        if let ds = pad as? GCDualSenseGamepad {
            attachTouchpadHandlers(primary: ds.touchpadPrimary,
                                   secondary: ds.touchpadSecondary)
            #if DEBUG
            debugTouchpadInstall[slot] = "DualSense typed, handlers attached, primary handler set=\(ds.touchpadPrimary.valueChangedHandler != nil)"
            #endif
        } else if let ds4 = pad as? GCDualShockGamepad {
            attachTouchpadHandlers(primary: ds4.touchpadPrimary,
                                   secondary: ds4.touchpadSecondary)
            #if DEBUG
            debugTouchpadInstall[slot] = "DualShock typed, handlers attached"
            #endif
        } else {
            #if DEBUG
            let dpads = Array(controller.physicalInputProfile.dpads.keys).sorted()
            debugTouchpadInstall[slot] = "generic \(type(of: pad)); profile dpads: \(dpads)"
            #endif
        }
    }

    /// Shared handler installer used by both the DualSense and DS4
    /// branches. Pulls the pair's latest (x, y) on every change and
    /// pushes both fingers through TouchpadService as a single
    /// transaction so a one-finger update doesn't latch finger 1 active.
    private func attachTouchpadHandlers(primary: GCControllerDirectionPad,
                                        secondary: GCControllerDirectionPad?) {
        // Capture the optional secondary outside the closure so the
        // closure body can read it without re-checking the type each
        // event. Apple guarantees these direction pad objects are
        // stable for the controller's lifetime.
        let sec = secondary
        let push: () -> Void = {
            let p1x = primary.xAxis.value
            let p1y = primary.yAxis.value
            let p1Active = abs(p1x) > 0.001 || abs(p1y) > 0.001
            let p2x = sec?.xAxis.value ?? 0
            let p2y = sec?.yAxis.value ?? 0
            let p2Active = sec != nil && (abs(p2x) > 0.001 || abs(p2y) > 0.001)
            TouchpadService.shared.ingestGameControllerTouchpad(
                f0Active: p1Active, f0NormalizedX: p1x, f0NormalizedY: p1y,
                f1Active: p2Active, f1NormalizedX: p2x, f1NormalizedY: p2y
            )
        }
        primary.valueChangedHandler = { _, _, _ in push() }
        secondary?.valueChangedHandler = { _, _, _ in push() }
    }

    private func feedTouchpadFromController(_ controller: GCController, slot: Int) {
        guard let pad = controller.extendedGamepad else { return }

        // Typed subclasses (DualSense / DualShock 4) are handled by
        // `installTouchpadHandlers`'s event-driven path which runs at
        // controller-native rate. Skip them here so we don't double-
        // write and don't waste cycles re-reading them every 33 ms.
        if pad is GCDualSenseGamepad || pad is GCDualShockGamepad {
            return
        }

        var f0Active = false
        var f0X: Float = 0
        var f0Y: Float = 0
        var f1Active = false
        var f1X: Float = 0
        var f1Y: Float = 0
        var sourced = false

        // Generic fallback for any other touchpad-capable controller
        // Apple exposes via the physical input profile. Some third-
        // party gamepads and future controllers ship with a touchpad
        // surface registered under names like "Touchpad 1" / "Touch 1".
        // Walk `pad.dpads` looking for those name patterns and use
        // whichever we find. This means future hardware that exposes
        // its surface through the standard profile will Just Work
        // without us shipping a new typed subclass per device.
        for (name, dpad) in pad.dpads {
            let lower = name.lowercased()
            guard lower.contains("touchpad") || lower.contains("touch ")
                    || lower.contains("trackpad") else { continue }
            let x = dpad.xAxis.value
            let y = dpad.yAxis.value
            let active = abs(x) > 0.001 || abs(y) > 0.001
            if lower.contains("2") || lower.contains("secondary") {
                f1X = x; f1Y = y; f1Active = active
            } else {
                f0X = x; f0Y = y; f0Active = active
            }
            sourced = true
        }

        guard sourced else { return }

        TouchpadService.shared.ingestGameControllerTouchpad(
            f0Active: f0Active, f0NormalizedX: f0X, f0NormalizedY: f0Y,
            f1Active: f1Active, f1NormalizedX: f1X, f1NormalizedY: f1Y
        )
    }

    // Memoized serialized input keys. accumulate() runs at 30 Hz for each
    // currently-active input; without these caches it rebuilt an InputEvent and
    // an interpolated String every tick. The key for a given (kind, index,
    // direction) never changes, so cache it on first use. Touched only on the
    // main actor (this is a @MainActor class), so plain dictionaries are safe.
    private var btnKeyCache: [Int: String] = [:]
    private var axisPosKeyCache: [Int: String] = [:]
    private var axisNegKeyCache: [Int: String] = [:]
    private var hatKeyCache: [Int: (u: String, d: String, l: String, r: String)] = [:]

    private func btnKey(_ i: Int) -> String {
        if let k = btnKeyCache[i] { return k }
        let k = InputEvent.button(i).serialized
        btnKeyCache[i] = k
        return k
    }
    private func axisKey(_ i: Int, positive: Bool) -> String {
        if positive {
            if let k = axisPosKeyCache[i] { return k }
            let k = InputEvent.axis(i, direction: .positive).serialized
            axisPosKeyCache[i] = k
            return k
        }
        if let k = axisNegKeyCache[i] { return k }
        let k = InputEvent.axis(i, direction: .negative).serialized
        axisNegKeyCache[i] = k
        return k
    }
    private func hatKeys(_ i: Int) -> (u: String, d: String, l: String, r: String) {
        if let k = hatKeyCache[i] { return k }
        let k = (InputEvent.hat(i, direction: .up).serialized,
                 InputEvent.hat(i, direction: .down).serialized,
                 InputEvent.hat(i, direction: .left).serialized,
                 InputEvent.hat(i, direction: .right).serialized)
        hatKeyCache[i] = k
        return k
    }

    /// Zones and gestures that are live right now, in the same serialized
    /// form a binding stores, so anything that highlights from
    /// `rawActiveInputs` lights up for them as well: touchpad zones and
    /// taps, stick zones, and screen regions while the cursor is sampled.
    private func accumulateRegions(into set: inout Set<String>) {
        let pad = TouchpadService.shared.snapshotRegions()
        for id in pad.pressed { set.insert(InputEvent.touchpadRegion(id).serialized) }
        for kind in TouchpadGestureKind.allCases where TouchpadService.shared.peekGesture(kind) {
            set.insert(InputEvent.touchpadGesture(kind).serialized)
        }
        if CursorRegionService.shared.isTracking {
            // The service decides, so a region that belongs to another
            // display stays dark here exactly as it stays silent in the engine.
            for r in CursorRegionService.shared.regions
            where CursorRegionService.shared.isRegionPressed(r.id) {
                set.insert(InputEvent.cursorRegion(r.id).serialized)
            }
        }
        // Any connected stick counts: a zone belongs to the stick, not to a
        // particular controller, so two pads mapping the same zone both
        // light the row.
        for (stick, list) in StickRegionService.shared.regionsByStick where !list.isEmpty {
            for state in scratchSnapshots.values {
                let x = Double(state.axes[stick * 2] ?? 0)
                let y = Double(state.axes[stick * 2 + 1] ?? 0)
                for r in list where r.contains(normalizedX: (x + 1) / 2, y: (y + 1) / 2) {
                    set.insert(InputEvent.stickRegion(stickIndex: stick, id: r.id).serialized)
                }
            }
        }
    }

    private func accumulate(into set: inout Set<String>, state: ControllerState) {
        for (index, value) in state.buttons where value > 0.5 {
            set.insert(btnKey(index))
        }
        for (index, value) in state.axes {
            if value > rawActiveAxisThreshold {
                set.insert(axisKey(index, positive: true))
            } else if value < -rawActiveAxisThreshold {
                set.insert(axisKey(index, positive: false))
            }
        }
        for (index, hat) in state.hats {
            let keys = hatKeys(index)
            if hat.y > rawActiveHatThreshold { set.insert(keys.u) }
            if hat.y < -rawActiveHatThreshold { set.insert(keys.d) }
            if hat.x < -rawActiveHatThreshold { set.insert(keys.l) }
            if hat.x > rawActiveHatThreshold { set.insert(keys.r) }
        }
    }

    // MARK: - Steam Controller integration

    /// Poll `SteamControllerService` at 2 Hz, syncing the synthesized virtual
    /// slot index + ControllerInfo so the rest of the app (sidebar status
    /// bar, preset detail metadata, binding row) sees a Steam Controller
    /// the same way it sees any MFi gamepad.
    private func startSteamControllerWatch() {
        steamWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncSteamControllerSlot()
            }
        }
        if let t = steamWatchTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func syncSteamControllerSlot() {
        let isConnected = SteamControllerService.shared.isConnected
        let desiredSlot = isConnected ? connectedControllers.count : nil

        if desiredSlot == steamControllerSlot { return }

        // Clean up any prior virtual entry.
        if let oldSlot = steamControllerSlot {
            controllerDetails.removeValue(forKey: oldSlot)
            controllerNames.removeValue(forKey: oldSlot)
        }

        steamControllerSlot = desiredSlot

        if let slot = desiredSlot {
            controllerNames[slot] = "Steam Controller"
            controllerDetails[slot] = ControllerInfo(
                name: "Steam Controller",
                productCategory: "Vendor HID",
                hasExtendedGamepad: false,
                hasLight: false,
                hasBattery: false,
                batteryLevel: nil,
                batteryState: nil,
                buttonCount: 23,
                axisCount: 6,
                supportsMotion: true,
                hasTouchpad: true,           // two trackpads
                hasMicroGamepad: false,
                hasAdaptiveTriggers: false,
                physicalButtonNames: SteamControllerButton.allCases.map(\.displayName),
                brand: .steamController
            )
        }
    }

    // MARK: - Raw HID Gamepad integration

    /// Poll `RawHIDGamepadService` at 2 Hz, allocating + reclaiming slot
    /// indices for HID gamepads the same way `syncSteamControllerSlot`
    /// does for the Steam Controller. Each detected gamepad gets a slot
    /// just past the MFi + Steam slots so existing preset slot
    /// indexes for native controllers stay stable.
    private func startRawHIDGamepadWatch() {
        // Idempotent. Stored on the instance so we don't leak timers
        // if the service is ever recreated (a previous version of
        // this method dropped the local `let timer` reference, which
        // kept polling forever in zombie service instances).
        rawHIDWatchTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncRawHIDGamepadSlots()
            }
        }
        rawHIDWatchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func syncRawHIDGamepadSlots() {
        let attached = RawHIDGamepadService.shared.connectedGamepads
        let baseIndex = connectedControllers.count + (steamControllerSlot != nil ? 1 : 0)

        // Build the desired (slot → gamepad) mapping from the current
        // attach list. Stable ordering: keep gamepads already mapped at
        // their current slot, then append any newcomers.
        var desired: [Int: RawHIDGamepad] = [:]
        let previouslyMappedIDs = Set(rawHIDGamepadSlots.values.map { $0.id })

        // First pass: preserve an existing slot only when it is still valid,
        // i.e. at or above the current base index. A slot assigned while no
        // MFi controller was present can fall below baseIndex once one
        // connects; keeping it there would let the raw-HID pad shadow the real
        // MFi controller, so such pads fall through to the second pass and get
        // re-based onto a free slot above the MFi range.
        var nextSlot = baseIndex
        var reservedSlots: Set<Int> = []
        for gamepad in attached where previouslyMappedIDs.contains(gamepad.id) {
            if let (oldSlot, _) = rawHIDGamepadSlots.first(where: { $0.value.id == gamepad.id }),
               oldSlot >= baseIndex {
                desired[oldSlot] = gamepad
                reservedSlots.insert(oldSlot)
            }
        }

        // Second pass: assign every gamepad not yet placed (newcomers and any
        // re-based from a now-invalid low slot) to the lowest free slot at or
        // above baseIndex.
        for gamepad in attached where !desired.values.contains(where: { $0.id == gamepad.id }) {
            while reservedSlots.contains(nextSlot) { nextSlot += 1 }
            desired[nextSlot] = gamepad
            reservedSlots.insert(nextSlot)
            nextSlot += 1
        }

        // Apply if changed. Equality is by slot key set + per-slot id.
        let changed = desired.count != rawHIDGamepadSlots.count
            || desired.contains(where: { rawHIDGamepadSlots[$0.key]?.id != $0.value.id })
        if changed {
            // Detach controller info for slots that are no longer used.
            let removedSlots = Set(rawHIDGamepadSlots.keys).subtracting(desired.keys)
            for slot in removedSlots {
                controllerDetails.removeValue(forKey: slot)
                controllerNames.removeValue(forKey: slot)
            }
            rawHIDGamepadSlots = desired
        }

        // Publish controller info for each active slot so the rest of the app
        // sees these gamepads like any other controller. This also runs when
        // the slot map did NOT change but the metadata is missing, because
        // refreshControllers wipes controllerNames/controllerDetails on every
        // MFi hot-plug and only repopulates the MFi slots; republishing here
        // keeps an unrelated MFi change from stranding the raw-HID slots without
        // metadata. The per-slot guard skips the writes in steady state (already
        // published, unchanged) so there is no spurious @Published churn.
        for (slot, gamepad) in rawHIDGamepadSlots where changed || controllerDetails[slot] == nil {
            let names = gamepad.profile?.physicalButtonNames
                ?? ControllerProfileDatabase.xinputButtonNames
            controllerNames[slot] = gamepad.displayName
            controllerDetails[slot] = ControllerInfo(
                name: gamepad.displayName,
                productCategory: "Raw HID",
                hasExtendedGamepad: true,
                hasLight: false,
                hasBattery: false,
                batteryLevel: nil,
                batteryState: nil,
                buttonCount: names.count,
                axisCount: 6,
                supportsMotion: false,
                hasTouchpad: false,
                hasMicroGamepad: false,
                hasAdaptiveTriggers: false,
                physicalButtonNames: names,
                brand: .unknown
            )
        }
    }

    private func extractButtonIndex(from name: String) -> Int {
        // Try to parse "Button 0", "Button A", etc.
        let digits = name.filter { $0.isNumber }
        return Int(digits) ?? 0
    }

    private func extractAxisIndex(from name: String) -> Int {
        let digits = name.filter { $0.isNumber }
        return Int(digits) ?? 0
    }

}
