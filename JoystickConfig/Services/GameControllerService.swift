import Foundation
import GameController
import Combine

/// Readable info about a connected controller
struct ControllerInfo {
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
}

/// Manages game controller detection and input reading
@MainActor
class GameControllerService: ObservableObject {
    @Published var connectedControllers: [GCController] = []
    @Published var controllerNames: [Int: String] = [:]
    @Published var controllerDetails: [Int: ControllerInfo] = [:]
    @Published var lightColors: [Int: (r: Float, g: Float, b: Float)] = [:]
    @Published var lightBrightness: [Int: UInt8] = [:] // 0=off, 1=dim, 2=bright
    @Published var lastInput: (joystickIndex: Int, inputEvent: InputEvent)?
    @Published var isScanning: Bool = false
    /// Serialized input event strings (e.g. "btn 5", "axi 0 +") that are
    /// currently pressed / deflected across *any* connected controller.
    /// Refreshed at 10 Hz independent of the mapping engine, so the editor's
    /// binding row highlight works even when no preset is running.
    @Published var rawActiveInputs: Set<String> = []

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
    @Published var recentPhysicalPresses: [PhysicalPressLog] = []

    /// One observed press from a physical input profile button.
    struct PhysicalPressLog: Identifiable {
        let id = UUID()
        let slot: Int
        let name: String
        let mappedIndex: Int?
        let at: Date
    }

    /// Cached mapping of physical profile button name -> button index for each controller slot.
    /// Built once on connection, used every poll frame to avoid re-sorting/re-matching at 120Hz.
    private var cachedExtraButtons: [Int: [(GCControllerButtonInput, Int)]] = [:]

    /// Live snapshot of every "extra" button (PS, mute, paddles, FN,
    /// share, etc.) registered for a controller slot. Each entry pairs
    /// a human-readable label with the current pressed value. The
    /// visualizer renders these as chips so users can see at a glance
    /// what their controller is reporting.
    struct ExtraButton: Identifiable {
        let id = UUID()
        let label: String
        let index: Int
        let pressed: Bool
    }

    func extraButtonsSnapshot(for slot: Int) -> [ExtraButton] {
        guard let cached = cachedExtraButtons[slot] else { return [] }
        return cached.map { (button, index) in
            ExtraButton(label: Self.labelForExtraButton(index: index, button: button),
                        index: index,
                        pressed: button.value > 0.5)
        }
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

    private var pollTimer: Timer?
    private var detailsTimer: Timer?
    private var steamWatchTimer: Timer?
    private var rawActivePollTimer: Timer?
    private var scanCallback: ((InputEvent) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Apple normally suppresses the Home / PS button event when an app
        // isn't actively claiming the controller. Setting this flag lets us
        // receive Home and other "background" events regardless of whether
        // the window has key focus.
        GCController.shouldMonitorBackgroundEvents = true

        setupControllerNotifications()
        refreshControllers()
        startDetailsPolling()
        // Spin up the Steam Controller helper at launch so the device is
        // detected immediately on plug-in. The helper does nothing until a
        // physical Steam Controller appears, then disables lizard mode and
        // starts streaming raw input reports. Re-running detection at 2 Hz
        // updates the virtual slot's ControllerInfo as the helper connects.
        SteamControllerService.shared.retain()
        startSteamControllerWatch()
        startRawActiveInputsPolling()
    }

    /// Periodically refresh battery level and other dynamic details
    private func startDetailsPolling() {
        detailsTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                for (index, controller) in self.connectedControllers.enumerated() {
                    self.controllerDetails[index] = self.buildControllerInfo(controller)
                }
            }
        }
    }

    // MARK: - Controller Discovery

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
                self?.refreshControllers()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil, queue: .main
        ) { [weak self] note in
            let name = (note.object as? GCController)?.vendorName ?? "Controller"
            Task { @MainActor in
                guard let self = self else { return }
                let stillConnected = !GCController.controllers().isEmpty
                StatsService.shared.controllerDisconnected(
                    name: name, anyStillConnected: stillConnected)
                self.refreshControllers()
            }
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
        connectedControllers = GCController.controllers()
        controllerNames.removeAll()
        controllerDetails.removeAll()
        cachedExtraButtons.removeAll()
        for (index, controller) in connectedControllers.enumerated() {
            cacheExtraButtons(for: controller, at: index)
            installPhysicalPressLogger(for: controller, slot: index)
            activateMotionSensors(for: controller)
            controllerNames[index] = controller.vendorName ?? "Controller \(index)"
            controllerDetails[index] = buildControllerInfo(controller)

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
            buttonCount: profile.buttons.count,
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
        guard let gamepad = controller.extendedGamepad else {
            cachedExtraButtons[index] = []
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
        // moment we cache. This lets users (and the Live Press Log in
        // Settings) see exactly what's surfaced - if the PS / mute /
        // paddle / FN buttons don't appear here AND none were found via
        // KVC above, Apple's framework isn't sending them and we can't
        // map them through standard MFi APIs.
        let profileButtonNames = Array(controller.physicalInputProfile.buttons.keys).sorted()
        #if DEBUG
        print("[GCS] Profile button names for \(controller.vendorName ?? "?"): \(profileButtonNames)")
        #endif

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
    }

    func controllerName(at index: Int) -> String {
        if index < connectedControllers.count {
            return connectedControllers[index].vendorName ?? "Controller \(index)"
        }
        // Steam Controller virtual slot just past the real MFi ones.
        if let steamSlot = steamControllerSlot, index == steamSlot {
            return "Steam Controller"
        }
        return "No controller in slot \(index)"
    }

    /// Set the controller's light bar color (DualSense, DualShock 4)
    func setControllerLight(at index: Int) {
        guard index < connectedControllers.count else { return }
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

    /// RGB cycle mode
    @Published var rgbCycleActive: [Int: Bool] = [:]
    private var rgbHue: Float = 0

    func toggleRGBCycle(at index: Int) {
        if rgbCycleActive[index] == true {
            stopRGBCycle(at: index)
        } else {
            startRGBCycle(at: index)
        }
    }

    private func startRGBCycle(at index: Int) {
        rgbCycleActive[index] = true
        rgbHue = 0
        cycleNextColor(at: index)
    }

    private func cycleNextColor(at index: Int) {
        guard rgbCycleActive[index] == true else { return }

        let (r, g, b) = Self.hsbToRGB(h: rgbHue, s: 1.0, b: 1.0)
        lightColors[index] = (r: r, g: g, b: b)
        applyLight(at: index, red: r, green: g, blue: b)
        rgbHue += 0.08
        if rgbHue > 1.0 { rgbHue -= 1.0 }

        // Schedule next color after the helper finishes (~1.2s accounts for agent kill + restart)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.cycleNextColor(at: index)
        }
    }

    func stopRGBCycle(at index: Int) {
        rgbCycleActive[index] = false
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

    /// Apply a light color WITHOUT storing it as the slot's default. Used by
    /// the mapping engine to flash a preset's chosen color while the preset
    /// is active; calling `setControllerLight(at:)` on stop restores the
    /// stored (user-default) color. Pass `brightness` to override the
    /// stored brightness for the duration; nil inherits.
    func applyTemporaryLight(at index: Int, red: Float, green: Float, blue: Float, brightness: UInt8? = nil) {
        guard index < connectedControllers.count else { return }
        let bri = brightness ?? lightBrightness[index] ?? 2
        let scale: Float = switch bri {
        case 0: 0.0
        case 1: 0.25
        default: 1.0
        }
        let r = UInt8(min(max(red * scale * 255, 0), 255))
        let g = UInt8(min(max(green * scale * 255, 0), 255))
        let b = UInt8(min(max(blue * scale * 255, 0), 255))
        HIDLightController.shared.setLightColor(red: r, green: g, blue: b)
    }

    /// Apply the light color via the LightHelper subprocess, scaling by brightness
    private func applyLight(at index: Int, red: Float, green: Float, blue: Float) {
        let brightness = lightBrightness[index] ?? 2
        let scale: Float = switch brightness {
        case 0: 0.0
        case 1: 0.25
        default: 1.0
        }
        let r = UInt8(min(max(red * scale * 255, 0), 255))
        let g = UInt8(min(max(green * scale * 255, 0), 255))
        let b = UInt8(min(max(blue * scale * 255, 0), 255))
        HIDLightController.shared.setLightColor(red: r, green: g, blue: b)
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
    }

    func stopScanning() {
        isScanning = false
        scanCallback = nil
        motionScanTimer?.invalidate()
        motionScanTimer = nil
        motionScanFiredThisGesture = false
        // Remove handlers
        for controller in connectedControllers {
            removeScanHandlers(for: controller)
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
        "Direction Pad", "Left Thumbstick", "Right Thumbstick"
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

        for (button, btnIndex) in allMappedButtons {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        let event = InputEvent.button(btnIndex)
                        self?.lastInput = (index, event)
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
                        self?.lastInput = (index, event)
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

        // --- D-pad ---
        gamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                var event: InputEvent?
                if yValue > 0.5 { event = InputEvent.hat(0, direction: .up) }
                else if yValue < -0.5 { event = InputEvent.hat(0, direction: .down) }
                else if xValue < -0.5 { event = InputEvent.hat(0, direction: .left) }
                else if xValue > 0.5 { event = InputEvent.hat(0, direction: .right) }

                if let event = event {
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }

        // --- Sticks ---
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                if abs(xValue) > 0.5 {
                    let event = InputEvent.axis(0, direction: xValue > 0 ? .positive : .negative)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
                if abs(yValue) > 0.5 {
                    let event = InputEvent.axis(1, direction: yValue > 0 ? .negative : .positive)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }

        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                if abs(xValue) > 0.5 {
                    let event = InputEvent.axis(2, direction: xValue > 0 ? .positive : .negative)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
                if abs(yValue) > 0.5 {
                    let event = InputEvent.axis(3, direction: yValue > 0 ? .negative : .positive)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }

        // --- Trigger analog axes ---
        gamepad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            if value > 0.5 {
                Task { @MainActor in
                    let event = InputEvent.axis(4, direction: .positive)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }

        gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            if value > 0.5 {
                Task { @MainActor in
                    let event = InputEvent.axis(5, direction: .positive)
                    self?.lastInput = (index, event)
                    self?.scanCallback?(event)
                }
            }
        }
    }

    private func setupPhysicalProfileScanHandlers(for controller: GCController, index: Int) {
        let profile = controller.physicalInputProfile

        for (name, button) in profile.buttons {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        // Try to extract button index from name
                        let btnIndex = self?.extractButtonIndex(from: name) ?? 0
                        let event = InputEvent.button(btnIndex)
                        self?.lastInput = (index, event)
                        self?.scanCallback?(event)
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
                        self?.lastInput = (index, event)
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

    // MARK: - Polling (for mapping engine)

    func readControllerState(at index: Int) -> ControllerState? {
        // Steam Controllers occupy the virtual slot just past the last
        // MFi controller. When a binding targets that slot we ask the
        // SteamControllerService for its synthesized ControllerState.
        if let steamIndex = steamControllerSlot, index == steamIndex {
            return SteamControllerService.shared.makeControllerState()
        }
        guard index < connectedControllers.count else { return nil }
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
                }
            }

            // --- Axes ---
            state.axes[0] = gamepad.leftThumbstick.xAxis.value
            state.axes[1] = -gamepad.leftThumbstick.yAxis.value
            state.axes[2] = gamepad.rightThumbstick.xAxis.value
            state.axes[3] = -gamepad.rightThumbstick.yAxis.value
            state.axes[4] = gamepad.leftTrigger.value
            state.axes[5] = gamepad.rightTrigger.value

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
                let (ax, ay, az) = MotionCalibrationService.shared.correctedAccel(
                    x: Float(motion.userAcceleration.x),
                    y: Float(motion.userAcceleration.y),
                    z: Float(motion.userAcceleration.z),
                    forKey: key)
                state.motion[.accelX] = ax
                state.motion[.accelY] = ay
                state.motion[.accelZ] = az
                if motion.hasRotationRate {
                    let (gx, gy, gz) = MotionCalibrationService.shared.correctedGyro(
                        x: Float(motion.rotationRate.x),
                        y: Float(motion.rotationRate.y),
                        z: Float(motion.rotationRate.z),
                        forKey: key)
                    state.motion[.gyroX] = gx
                    state.motion[.gyroY] = gy
                    state.motion[.gyroZ] = gz
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
            // Physical input profile fallback for non-standard controllers
            let profile = controller.physicalInputProfile
            for (name, button) in profile.buttons {
                let idx = extractButtonIndex(from: name)
                state.buttons[idx] = button.value
            }
            for (name, axis) in profile.axes {
                let idx = extractAxisIndex(from: name)
                state.axes[idx] = axis.value
            }
        }

        return state
    }

    // MARK: - Helpers

    // MARK: - Physical press diagnostic log

    /// Install a pass-through press logger on every button in the
    /// physical input profile. Fires alongside (NOT instead of) the
    /// scan / read handlers so we can show the user EXACTLY which name
    /// Apple's framework reports for the button they just pressed. The
    /// Settings > Controllers diagnostic surfaces this list.
    private func installPhysicalPressLogger(for controller: GCController, slot: Int) {
        let profile = controller.physicalInputProfile
        for (name, button) in profile.buttons {
            // Skip the composite "Direction Pad", thumbsticks, etc.
            if Self.ignoredProfileNames.contains(where: { name.contains($0) }) { continue }
            // Capture any prior handler (set by setupScanHandlers or our
            // cache loop) so we can call it after logging.
            let prior = button.pressedChangedHandler
            let mappedIndex = Self.knownButtonMap[name]
                ?? (cachedExtraButtons[slot]?.first(where: { ObjectIdentifier($0.0) == ObjectIdentifier(button) })?.1)
            button.pressedChangedHandler = { [weak self] btn, value, pressed in
                if pressed {
                    Task { @MainActor in
                        self?.logPhysicalPress(name: name, slot: slot, mappedIndex: mappedIndex)
                    }
                }
                prior?(btn, value, pressed)
            }
        }
    }

    private func logPhysicalPress(name: String, slot: Int, mappedIndex: Int?) {
        let entry = PhysicalPressLog(slot: slot, name: name, mappedIndex: mappedIndex, at: Date())
        recentPhysicalPresses.insert(entry, at: 0)
        if recentPhysicalPresses.count > 30 {
            recentPhysicalPresses.removeLast(recentPhysicalPresses.count - 30)
        }
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
            Task { @MainActor in
                self?.refreshRawActiveInputs()
            }
        }
        if let t = rawActivePollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// Snapshot every connected controller's current state and turn pressed
    /// buttons / deflected axes / hat directions into the serialized strings
    /// the editor uses to match binding rows. Each detected input gets a
    /// 200 ms expiry so quick taps remain visible.
    private func refreshRawActiveInputs() {
        var freshlyActive = Set<String>()
        var snapshots: [Int: ControllerState] = [:]
        // Real MFi controllers
        for i in connectedControllers.indices {
            guard let state = readControllerState(at: i) else { continue }
            snapshots[i] = state
            accumulate(into: &freshlyActive, state: state)
        }
        // Steam Controller virtual slot
        if let slot = steamControllerSlot, let state = readControllerState(at: slot) {
            snapshots[slot] = state
            accumulate(into: &freshlyActive, state: state)
        }
        // ControllerState isn't Equatable (its hat tuples can't auto-derive
        // it), so always assign. Cost is negligible for 1-2 controllers at
        // 30 Hz.
        currentStates = snapshots

        // Stamp expiry timestamps for everything currently pressed.
        let now = Date()
        let expiryDate = now.addingTimeInterval(rawActiveLingerSeconds)
        for key in freshlyActive {
            rawActiveExpiry[key] = expiryDate
        }
        // Drop entries whose expiry has passed.
        rawActiveExpiry = rawActiveExpiry.filter { $0.value > now }
        let combined = Set(rawActiveExpiry.keys)
        if combined != rawActiveInputs {
            rawActiveInputs = combined
        }
    }

    private func accumulate(into set: inout Set<String>, state: ControllerState) {
        for (index, value) in state.buttons where value > 0.5 {
            set.insert(InputEvent.button(index).serialized)
        }
        for (index, value) in state.axes {
            if value > rawActiveAxisThreshold {
                set.insert(InputEvent.axis(index, direction: .positive).serialized)
            } else if value < -rawActiveAxisThreshold {
                set.insert(InputEvent.axis(index, direction: .negative).serialized)
            }
        }
        for (index, hat) in state.hats {
            if hat.y > rawActiveHatThreshold {
                set.insert(InputEvent.hat(index, direction: .up).serialized)
            }
            if hat.y < -rawActiveHatThreshold {
                set.insert(InputEvent.hat(index, direction: .down).serialized)
            }
            if hat.x < -rawActiveHatThreshold {
                set.insert(InputEvent.hat(index, direction: .left).serialized)
            }
            if hat.x > rawActiveHatThreshold {
                set.insert(InputEvent.hat(index, direction: .right).serialized)
            }
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
