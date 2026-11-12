import Foundation
import Combine
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
#if canImport(AppKit)
import AppKit
#endif

/// External-input monitoring service: lets the user bind their Mac's
/// mouse / trackpad (and, on an Accessibility-only basis, keyboard) as
/// **input sources** for a preset.
///
/// ## Permission model (App Store safe)
///
/// Earlier builds used an `IOHIDManager` matched on keyboard / mouse
/// usages plus a CGEventTap that consumed the raw keystroke stream. That
/// required the Input Monitoring permission, which App Store review
/// (guideline 2.4.5) rejects for a non-accessibility purpose, so it was
/// removed. This version rides only on the app's single approved
/// permission, **Accessibility**:
///   - Mouse / trackpad: a listen-only `CGEventTap` for mouse events
///     (buttons, scroll, movement). Mouse events do not require Input
///     Monitoring, so this needs only Accessibility.
///   - Keyboard: AppKit `NSEvent` global + local monitors (the
///     Accessibility API path), gated on `AXIsProcessTrusted()` and only
///     started for presets that actually use a `.extKey` binding. No
///     IOHID, no keystroke-stream CGEventTap, no Input Monitoring prompt.
///
/// Everything is gated so nothing runs until Accessibility is granted and
/// someone needs it. Monitoring is reference counted: the running engine,
/// the Live Visualizer's keyboard and mouse templates, and the editor's
/// Scan each `retain` what they need and `release` it when done, and each
/// monitor runs only while at least one of them holds it.
///   - `events` fires mouse events while the mouse monitor is active and
///     keyboard events while the keyboard monitor is.
///   - `rawActiveInputs` is the live picture for the UI: keys and buttons
///     held right now, plus movement, scroll, and Force Touch for a moment
///     after they happen, in the same serialized form as bindings.
///   - `devices` lists the synthetic Mouse / Keyboard entries while the
///     matching monitor is active.
///
/// Game controllers are unaffected - they come through the GameController
/// framework (`GameControllerService`) and raw HID *gamepads* through
/// `RawHIDGamepadService`, neither of which needs Input Monitoring.
/// Cursor-position based bindings (`.cursorRegion`) read
/// `NSEvent.mouseLocation` directly in `CursorRegionService`.
final class ExternalInputDeviceService: ObservableObject, @unchecked Sendable {
    static let shared = ExternalInputDeviceService()

    // MARK: - Public types (preserved for the binding model + views)

    enum Bus: String, Codable {
        case usb, bluetooth, builtIn, unknown
    }

    enum Kind: String, Codable {
        case keyboard, mouse, keypad

        /// "Any keyboard" and so on, a whole phrase per kind for the device menus.
        var anyDevice: String {
            switch self {
            case .keyboard: return String(localized: "Any keyboard")
            case .mouse: return String(localized: "Any mouse")
            case .keypad: return String(localized: "Any keypad")
            }
        }
    }

    struct Device: Identifiable, Hashable {
        let id: String
        let kind: Kind
        let vendorID: Int
        let productID: Int
        let vendorName: String
        let productName: String
        let serialNumber: String?
        let bus: Bus
        let locationID: Int
    }

    enum Event: Hashable {
        case keyDown(deviceID: String, hidCode: Int)
        case keyUp(deviceID: String, hidCode: Int)
        case mouseButtonDown(deviceID: String, button: Int)
        case mouseButtonUp(deviceID: String, button: Int)
        case mouseMove(deviceID: String, dx: Int, dy: Int)
        case scroll(deviceID: String, dx: Int, dy: Int)
        /// Force Touch pressure update from the Mac trackpad. value is the
        /// 0-1 press force; stage is 0 (no click), 1 (click), 2 (force click).
        case pressureChanged(deviceID: String, value: Float, stage: Int)
        /// The second click of a double click, as macOS counted it.
        case mouseDoubleClick(deviceID: String, button: Int)
        /// A finger scroll gesture started (true) or finished, momentum
        /// included (false). Wheel mice never send this.
        case scrollGesture(deviceID: String, active: Bool)
        /// A pen tablet pointer event (CGEventType 23): tip pressure 0 to 1,
        /// tilt -1 to 1 each way, the barrel button bitmask.
        case tabletPoint(deviceID: String, pressure: Float, tiltX: Float, tiltY: Float, buttons: Int)
        /// A pen entered (true) or left the tablet's range; eraser says
        /// which end is near.
        case tabletProximity(deviceID: String, entering: Bool, eraser: Bool)

        var deviceID: String {
            switch self {
            case .keyDown(let id, _), .keyUp(let id, _),
                 .mouseButtonDown(let id, _), .mouseButtonUp(let id, _),
                 .mouseMove(let id, _, _), .scroll(let id, _, _),
                 .pressureChanged(let id, _, _), .mouseDoubleClick(let id, _),
                 .scrollGesture(let id, _), .tabletPoint(let id, _, _, _, _), .tabletProximity(let id, _, _):
                return id
            }
        }
    }

    struct LoggedEvent: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let label: String
    }

    // MARK: - Published state

    /// Synthetic device entries (a Mouse and / or Keyboard row) for whichever
    /// monitors are currently active. Empty until a running preset that uses an
    /// external-input binding starts monitoring and Accessibility is granted.
    @Published private(set) var devices: [Device] = []
    @Published private(set) var recentEvents: [String: [LoggedEvent]] = [:]
    @Published private(set) var receivedAnyKeyboardEvent = false

    /// Live Force Touch pressure metrics for UI gauges (0-1 force and the
    /// click stage). Published only on meaningful change so a slow press
    /// does not render-storm observers.
    @Published private(set) var trackpadPressure: Float = 0
    @Published private(set) var trackpadPressureStage: Int = 0
    @Published private(set) var rawActiveInputs: Set<String> = []

    /// What a finger scroll is doing right now, for the visualizer.
    enum ScrollGesture: String { case none, fingers, momentum }
    @Published private(set) var scrollGesture: ScrollGesture = .none

    /// The last raw keyboard events seen by the monitors and the tap,
    /// before any decoding, for the debug hook. Type, keyCode, flags, and
    /// for system-defined events the subtype and data1.
    /// Debug builds only: a release build keeps no record of anyone's
    /// keystrokes, not even in memory, and does not format the lines.
    private(set) var debugEventLog: [String] = []
    private func logRaw(_ line: @autoclosure () -> String) {
        #if DEBUG
        debugEventLog.append(line())
        if debugEventLog.count > 60 { debugEventLog.removeFirst(debugEventLog.count - 60) }
        #endif
    }

    /// One line per fact, for the debug hook.
    var debugState: String {
        """
        accessibility=\(accessibilityGranted)
        mouseConsumers=\(mouseConsumers.sorted()) keyboardConsumers=\(keyboardConsumers.sorted())
        tapInstalled=\(cgEventTapInstalled) keyboardMonitors=\(keyboardGlobalMonitor != nil)/\(keyboardLocalMonitor != nil)
        sysDefinedTap=\(sysDefinedTap != nil) liveTimer=\(liveTimer != nil) liveUntil=\(liveUntil.keys.sorted())
        rawActiveInputs=\(rawActiveInputs.sorted())
        scrollGesture=\(scrollGesture.rawValue) pressure=\(trackpadPressure) stage=\(trackpadPressureStage)
        rawEvents:
        \(debugEventLog.joined(separator: "\n"))
        """
    }

    /// Fires mouse events while `startMouseMonitoring()` is active and keyboard
    /// events while `startKeyboardMonitoring()` is active. Idle until a running
    /// preset actually uses an external-input binding.
    let events = PassthroughSubject<Event, Never>()

    /// True while the listen-only mouse `CGEventTap` is installed.
    @Published private(set) var cgEventTapInstalled = false
    @Published private(set) var cgEventTapReceivedAnyEvent = false
    /// A password field has the keyboard (Secure Event Input): the global
    /// monitor gets no key events until it lets go. Polled while keys are
    /// being read, so the Live Visualizer and Scan can say why keys are quiet.
    @Published private(set) var secureInputBlocking = false

    /// Synthetic device IDs kept only so binding strings saved by older
    /// builds ("ekb 4 builtin.keyboard") still parse without crashing.
    static let builtInKeyboardID = "builtin.keyboard"
    static let builtInMouseID = "builtin.mouse"

    static let excludeBuiltInKey = "InputConfig.externalInput.excludeBuiltIn"

    /// Retained as a stored preference only so Settings' existing toggle
    /// and the backup key list keep working. It no longer gates any
    /// monitoring because there is no monitoring.
    @Published var excludeBuiltInDevices: Bool {
        didSet {
            UserDefaults.standard.set(excludeBuiltInDevices, forKey: Self.excludeBuiltInKey)
        }
    }

    private init() {
        excludeBuiltInDevices = UserDefaults.standard.bool(forKey: Self.excludeBuiltInKey)
        // Follow the Accessibility grant. Nothing did: granting it after a
        // preset started left Mac keyboard and mouse rows dead until the
        // preset restarted, and a revoke then re-grant never made the tap
        // again. Consumers are kept across a revoke, so the grant brings
        // back exactly what was wanted.
        Task { @MainActor [weak self] in
            self?.trustSubscription = AccessibilityPermissionService.shared.$isTrusted
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] trusted in
                    guard let self else { return }
                    if trusted {
                        self.applyMonitoring()
                        // The key block the running preset asked for, made
                        // now: before the grant installKeyTap could not, and
                        // a revoke dropped it, so no key was held back.
                        if !self.blockedKeys.isEmpty, self.keyTap == nil {
                            self.installKeyTap()
                        }
                    } else {
                        self.stopMouseMonitoring()
                        self.stopKeyboardMonitoring()
                        // The blocking taps too: kept, they came back after
                        // a re-grant possibly disabled, nothing read the
                        // middle and side buttons, and with the key tap
                        // still set the monitors dropped every key, so
                        // keyboard rows stayed dead. blockedKeys is kept
                        // for the re-grant.
                        self.destroyButtonTap()
                        self.destroyKeyTap()
                    }
                }
        }
    }

    private var trustSubscription: AnyCancellable?

    // MARK: - Reference-counted monitoring

    private var mouseConsumers: Set<String> = []
    private var keyboardConsumers: Set<String> = []
    /// Mouse consumers that read pointer movement. The tap takes movement
    /// and drag events only for them: up to 1000 a second from a gaming
    /// mouse went through the tap for presets that bind only a button.
    private var movementConsumers: Set<String> = []
    private var tapHasMovement = false

    /// Whether the app may listen at all. Both monitors ride on the
    /// Accessibility permission; without it nothing is installed.
    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Hold the mouse and / or keyboard monitor open under `reason`. Calling
    /// again with the same reason replaces what that reason holds. Safe
    /// before Accessibility is granted: the monitor is installed the next
    /// time anyone retains after the grant.
    func retain(_ reason: String, mouse: Bool = false, keyboard: Bool = false, movement: Bool = true) {
        if mouse { mouseConsumers.insert(reason) } else { mouseConsumers.remove(reason) }
        if mouse && movement { movementConsumers.insert(reason) } else { movementConsumers.remove(reason) }
        if keyboard { keyboardConsumers.insert(reason) } else { keyboardConsumers.remove(reason) }
        applyMonitoring()
    }

    /// Let go of whatever `reason` was holding. The last release of a
    /// monitor tears it down.
    func release(_ reason: String) {
        mouseConsumers.remove(reason)
        movementConsumers.remove(reason)
        keyboardConsumers.remove(reason)
        applyMonitoring()
    }

    private func applyMonitoring() {
        // The tap's mask is fixed when it is made; a change in who reads
        // movement makes it again.
        if mouseConsumers.isEmpty {
            stopMouseMonitoring()
        } else if eventTap != nil, tapHasMovement != !movementConsumers.isEmpty {
            restartMouseMonitoring()
        } else {
            startMouseMonitoring()
        }
        if keyboardConsumers.isEmpty { stopKeyboardMonitoring() } else { startKeyboardMonitoring() }
        if mouseConsumers.isEmpty && keyboardConsumers.isEmpty {
            liveTimer?.invalidate(); liveTimer = nil
            liveUntil.removeAll()
            if !rawActiveInputs.isEmpty { rawActiveInputs = [] }
        } else if liveTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.publishLive()
            }
            RunLoop.main.add(t, forMode: .common)
            liveTimer = t
        }
    }

    // MARK: - Live picture

    /// Each active serialized input and when it stops counting. Held keys
    /// and buttons are `.distantFuture` until their release arrives;
    /// movement, scroll, and pressure get a short window so a flick still
    /// shows. Every entry is written twice, once for "any" device and once
    /// for the synthetic device id, so bindings saved either way match.
    private var liveUntil: [String: Date] = [:]
    private var liveTimer: Timer?
    private static let momentaryWindow: TimeInterval = 0.18

    private func mark(_ body: String, dev: String, until: Date) {
        liveUntil["\(body) any"] = until
        liveUntil["\(body) \(dev)"] = until
    }
    private func unmark(_ body: String, dev: String) {
        liveUntil.removeValue(forKey: "\(body) any")
        liveUntil.removeValue(forKey: "\(body) \(dev)")
    }

    #if DEBUG
    /// Marketing capture only: light a set of keys and mouse inputs in the
    /// visualizer for a few seconds without touching the real devices.
    /// `spec` is ";"-separated bodies in the stored form, e.g.
    /// "ekb 4;ekb 44;ems button 0 +;ems scrollGesture 0 +".
    func debugMark(spec: String, seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        for raw in spec.split(separator: ";") {
            let body = raw.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let dev = body.hasPrefix("ekb") ? Self.builtInKeyboardID : Self.builtInMouseID
            mark(body, dev: dev, until: until)
        }
        publishLive()
    }
    #endif

    /// Fold one event into the live picture. Called for every event the
    /// monitors deliver, on the main run loop.
    #if DEBUG
    /// Tests only: an event as the keyboard or mouse monitors deliver it.
    func debugInject(_ e: Event) {
        noteLive(e)
        events.send(e)
    }
    #endif

    private func noteLive(_ e: Event) {
        let soon = Date().addingTimeInterval(Self.momentaryWindow)
        switch e {
        case .keyDown(let dev, let code):        mark("ekb \(code)", dev: dev, until: .distantFuture)
        case .keyUp(let dev, let code):          unmark("ekb \(code)", dev: dev)
        case .mouseButtonDown(let dev, let b):   mark("ems button \(b) +", dev: dev, until: .distantFuture)
        case .mouseButtonUp(let dev, let b):     unmark("ems button \(b) +", dev: dev)
        case .mouseMove(let dev, let dx, let dy):
            if dx != 0 { mark("ems moveX 0 \(dx > 0 ? "+" : "-")", dev: dev, until: soon) }
            if dy != 0 { mark("ems moveY 0 \(dy > 0 ? "+" : "-")", dev: dev, until: soon) }
        case .scroll(let dev, let dx, let dy):
            if dx != 0 { mark("ems scrollX 0 \(dx > 0 ? "+" : "-")", dev: dev, until: soon) }
            if dy != 0 { mark("ems scrollY 0 \(dy > 0 ? "+" : "-")", dev: dev, until: soon) }
        case .pressureChanged(let dev, let value, let stage):
            if value > 0.25 { mark("ems pressure 0 +", dev: dev, until: .distantFuture) } else { unmark("ems pressure 0 +", dev: dev) }
            if stage >= 2 { mark("ems deepPress 0 +", dev: dev, until: .distantFuture) } else { unmark("ems deepPress 0 +", dev: dev) }
        case .mouseDoubleClick(let dev, let b):
            mark("ems doubleClick \(b) +", dev: dev, until: Date().addingTimeInterval(0.35))
        case .scrollGesture(let dev, let active):
            if active { mark("ems scrollGesture 0 +", dev: dev, until: .distantFuture) } else { unmark("ems scrollGesture 0 +", dev: dev) }
        case .tabletPoint(let dev, let pressure, let tiltX, let tiltY, let buttons):
            if pressure > Self.penPressureThreshold { mark("ems penPressure 0 +", dev: dev, until: .distantFuture) } else { unmark("ems penPressure 0 +", dev: dev) }
            for (kind, value) in [("penTiltX", tiltX), ("penTiltY", tiltY)] {
                if value > Self.penTiltThreshold { mark("ems \(kind) 0 +", dev: dev, until: .distantFuture) } else { unmark("ems \(kind) 0 +", dev: dev) }
                if value < -Self.penTiltThreshold { mark("ems \(kind) 0 -", dev: dev, until: .distantFuture) } else { unmark("ems \(kind) 0 -", dev: dev) }
            }
            for bit in 0..<8 {
                if buttons & (1 << bit) != 0 { mark("ems penButton \(bit) +", dev: dev, until: .distantFuture) } else { unmark("ems penButton \(bit) +", dev: dev) }
            }
        case .tabletProximity(let dev, let entering, let eraser):
            if entering { mark("ems penInRange 0 +", dev: dev, until: .distantFuture) } else { unmark("ems penInRange 0 +", dev: dev) }
            if entering && eraser { mark("ems penEraser 0 +", dev: dev, until: .distantFuture) } else { unmark("ems penEraser 0 +", dev: dev) }
        }
    }

    static let penPressureThreshold: Float = 0.1
    static let penTiltThreshold: Float = 0.25
    static let tabletID = "tablet"

    /// A tablet pointer event's fields (CGEventTypes.h kCGTabletEventPointPressure 19,
    /// TiltX 20, TiltY 21, PointButtons 18).
    static func tabletPoint(of event: CGEvent) -> (pressure: Float, tiltX: Float, tiltY: Float, buttons: Int) {
        (Float(event.getDoubleValueField(.tabletEventPointPressure)),
         Float(event.getDoubleValueField(.tabletEventTiltX)),
         Float(event.getDoubleValueField(.tabletEventTiltY)),
         Int(event.getIntegerValueField(.tabletEventPointButtons)))
    }

    /// A tablet proximity event's fields: kCGTabletProximityEventEnterProximity
    /// (38) and PointerType (37; NSPointingDeviceType 3 is the eraser).
    static func tabletProximity(of event: CGEvent) -> (entering: Bool, eraser: Bool) {
        (event.getIntegerValueField(.tabletProximityEventEnterProximity) != 0,
         event.getIntegerValueField(.tabletProximityEventPointerType) == 3)
    }

    /// Keys read by asking macOS for their physical state each tick rather
    /// than waiting for an event: the modifiers, whose flagsChanged the
    /// monitors can miss (reconciled here; an edge they did report is not
    /// sent twice), and the top-row keys macOS keeps to itself. `CGEventSource.keyState` answers for any key without Input
    /// Monitoring. Virtual keycode to the HID code the app stores.
    private static let polledKeys: [(vk: CGKeyCode, hid: Int)] = [
        (56, 225), (60, 229),   // left / right Shift
        (59, 224), (62, 228),   // left / right Control
        (58, 226), (61, 230),   // left / right Option
        (55, 227), (54, 231),   // left / right Command
        (57, 57),               // Caps Lock, as a press
        (63, KeyCodeMap.globeFnCode),   // fn held
        (160, 304), (131, 303), (177, KeyCodeMap.spotlightKeyCode),
        (176, KeyCodeMap.dictationKeyCode), (178, KeyCodeMap.focusKeyCode),
    ]
    private var polledDown: Set<Int> = []

    /// Both sides' device bits for each side-specific modifier key.
    private static let modifierFamilyBits: [Int: UInt] = [
        56: 0x0000_0006, 60: 0x0000_0006,   // Shift
        59: 0x0000_2001, 62: 0x0000_2001,   // Control
        58: 0x0000_0060, 61: 0x0000_0060,   // Option
        55: 0x0000_0018, 54: 0x0000_0018,   // Command
    ]

    /// Whether a polled key is down. A side-specific modifier is read from
    /// its own device bit in the session's modifier flags: the key state
    /// answers for the modifier, not the key, so right Command and right
    /// Option read as the left ones too. A keyboard that sets no device bits
    /// falls back to the key state, as before.
    /// The family is tested on the session's full flags, the side on the
    /// flags without this app's own posted bits. While only the app holds
    /// a modifier, the family is set and the person's side reads up; the
    /// key state is never asked then, since it counts the app's own key and
    /// latched the other side.
    private static func isDown(_ vk: CGKeyCode, flags raw: UInt, own: UInt) -> Bool {
        if let family = modifierFamilyBits[Int(vk)], let bit = modifierDeviceBit[Int(vk)], raw & family != 0 {
            return (raw & ~own) & bit != 0
        }
        return CGEventSource.keyState(.combinedSessionState, key: vk)
    }

    private func pollKeys() {
        guard !keyboardConsumers.isEmpty else { return }
        let dev = Self.builtInKeyboardID
        // Without the side bits this app's own posted modifiers carry: a
        // row turning right Option into left Option otherwise read the
        // posted left bit as the right key being let go, and flickered.
        let flags = UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        let own = InputSimulator.shared.ownDeviceModifierBits()
        for entry in Self.polledKeys {
            // keyState includes the events this app posts, and the own-event
            // marker only protects the event tap. Without this a preset that
            // swaps Command and Control read its own output as input and
            // latched both, and any row sending a modifier fired the rows
            // bound to that modifier as an input.
            if InputSimulator.shared.isHolding(entry.hid) { continue }
            let down = Self.isDown(entry.vk, flags: flags, own: own)
            let was = polledDown.contains(entry.hid)
            guard down != was else { continue }
            if down { polledDown.insert(entry.hid) } else { polledDown.remove(entry.hid) }
            logRaw("poll \(down ? "keyDown" : "keyUp") vk=\(entry.vk)")
            let e: Event = down ? .keyDown(deviceID: dev, hidCode: entry.hid) : .keyUp(deviceID: dev, hidCode: entry.hid)
            if down, !receivedAnyKeyboardEvent { receivedAnyKeyboardEvent = true }
            noteLive(e); events.send(e)
        }
    }

    /// One modifier's edge from its flagsChanged event, read the way the
    /// poll reads it (`isDown`) and recorded in the same held set, so the
    /// next poll sees nothing new for it. Only the side-specific pairs;
    /// a key the app itself holds is skipped, as in the poll.
    private func noteModifierEdge(vk: CGKeyCode, flags: UInt, dev: String) {
        guard !keyboardConsumers.isEmpty,
              Self.modifierFamilyBits[Int(vk)] != nil,
              let entry = Self.polledKeys.first(where: { $0.vk == vk }) else { return }
        if InputSimulator.shared.isHolding(entry.hid) { return }
        let own = InputSimulator.shared.ownDeviceModifierBits()
        let down = Self.isDown(vk, flags: flags, own: own)
        let was = polledDown.contains(entry.hid)
        guard down != was else { return }
        if down { polledDown.insert(entry.hid) } else { polledDown.remove(entry.hid) }
        logRaw("flags \(down ? "keyDown" : "keyUp") vk=\(vk)")
        let e: Event = down ? .keyDown(deviceID: dev, hidCode: entry.hid) : .keyUp(deviceID: dev, hidCode: entry.hid)
        if down, !receivedAnyKeyboardEvent { receivedAnyKeyboardEvent = true }
        noteLive(e); events.send(e)
    }

    /// 30 Hz: read the polled keys, drop what has timed out, and publish
    /// only when the set changed.
    private func publishLive() {
        pollKeys()
        reconcileHeld()
        let secure = !keyboardConsumers.isEmpty && IsSecureEventInputEnabled()
        if secure != secureInputBlocking {
            secureInputBlocking = secure
            // "Ended" only when Secure Input itself went off while keyboard
            // rows were read; with the readers gone there is nothing to resume.
            if secure || !keyboardConsumers.isEmpty {
                ActivityLog.shared.info("Keyboard", secure
                    ? "A password field has the keyboard (Secure Input): keyboard rows pause until it is dismissed"
                    : "Secure Input ended: keyboard rows resume")
            }
        }
        let now = Date()
        for (k, until) in liveUntil where until <= now { liveUntil.removeValue(forKey: k) }
        if liveUntil.count != rawActiveInputs.count || !rawActiveInputs.isSuperset(of: liveUntil.keys) {
            rawActiveInputs = Set(liveUntil.keys)
        }
    }

    /// A key or button still marked held that the system says is up lost
    /// its release (Secure Event Input swallows events for the global
    /// monitor, and a monitor rebuild can drop one), and a bound output
    /// stayed down. Release it here, as if the event had arrived.
    private func reconcileHeld() {
        let polled = Set(Self.polledKeys.map(\.hid))
        for key in liveUntil.keys where liveUntil[key] == .distantFuture && !key.hasSuffix(" any") {
            let parts = key.split(separator: " ")
            // Not the Globe key: its press is a system-made key-down that
            // the key state never reports as held, so it was let go on the
            // next tick. Its real key-up still arrives and releases it.
            if parts.count == 3, parts[0] == "ekb", let code = Int(parts[1]), !polled.contains(code),
               code != KeyCodeMap.globeKeyCode, code != KeyCodeMap.globeFnCode,
               // A key with no name is stored as its key code past the base.
               let vk = KeyCodeMap.hidToVirtualKeyCode[code]
                    ?? ((KeyCodeMap.unknownKeyBase..<KeyCodeMap.unknownSystemKeyBase).contains(code)
                        ? code - KeyCodeMap.unknownKeyBase : nil),
               !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(vk)) {
                let e: Event = .keyUp(deviceID: String(parts[2]), hidCode: code)
                // The tap missed it too (Secure Input hides keys from it):
                // the engine answers for the key until the tap sees it again.
                locked { if tapKeysDown.remove(code) != nil { tapKeysSeen.remove(code) } }
                noteLive(e); events.send(e)
            } else if parts.count == 5, parts[0] == "ems", parts[1] == "button", let b = Int(parts[2]),
                      // CGMouseButton defines left, right and center only
                      // (CGEventTypes.h); the window server's answer for 3 to
                      // 31 is undefined, and a false there released every held
                      // side button 33 ms after its press. The tap sees every
                      // otherMouseUp, so those are trusted to it.
                      b <= 2, let button = CGMouseButton(rawValue: UInt32(b)),
                      !CGEventSource.buttonState(.combinedSessionState, button: button) {
                let e: Event = .mouseButtonUp(deviceID: String(parts[4]), button: b)
                locked { if tapButtonsDown.remove(b) != nil { tapButtonsSeen.remove(b) } }
                noteLive(e); events.send(e)
            }
        }
    }

    // MARK: - Public lookup (return empty / nil)

    func deviceName(for id: String) -> String? {
        devices.first(where: { $0.id == id })?.productName
    }

    // MARK: - The taps' own thread

    /// The run loop every tap here runs on: the key and button blocking
    /// taps, the listen tap and the media key tap. On the main run loop,
    /// each keystroke on the Mac waited while a preset switch laid out the
    /// page (95 to 140 ms), and a longer stall made macOS turn the block off,
    /// so a blocked key did its own action. Started with the first tap and
    /// kept, like the wheel shaper's thread; a port keeps it running with no
    /// tap in it.
    nonisolated(unsafe) private static let tapLoop: CFRunLoop = {
        let box = TapLoopBox()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.loop = CFRunLoopGetCurrent()
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "InputConfig.InputTaps"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return box.loop!
    }()
    private final class TapLoopBox: @unchecked Sendable { var loop: CFRunLoop? }

    /// A tap's source onto the taps' loop, woken so it listens at once.
    private static func addToTapLoop(_ source: CFRunLoopSource?) {
        CFRunLoopAddSource(tapLoop, source, .commonModes)
        CFRunLoopWakeUp(tapLoop)
    }

    /// Guards what the tap callbacks read and write on the taps' thread.
    /// The taps, the blocked keys and buttons with their chords and pause
    /// lists, `selfInFront`, the engine's answers (`pointerPassing`,
    /// `heldChordMembers`) and the teardown flags are written on main under
    /// it, and main reads them without it, being their only writer. The
    /// swallowed sets, the keys and buttons the taps saw held
    /// (`tapKeysDown`, `tapButtonsDown`) and the timeout flags, which the
    /// callbacks write, are read and written under it everywhere. Never taken twice on one path: NSLock is
    /// not recursive.
    private let tapLock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        tapLock.lock()
        defer { tapLock.unlock() }
        return body()
    }

    /// A tap's event on its way to main: the event is the system's and
    /// lives only for the callback, so main gets a copy.
    fileprivate struct EventCopy: @unchecked Sendable { let event: CGEvent }

    // MARK: - Mouse input monitoring (Accessibility-gated)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Active tap for middle and side button presses, installed only while
    /// a running preset blocks one of them (`blockedMouseButtons`). The
    /// listen-only tap above stops taking those events meanwhile, so each
    /// press is reported once, and cursor motion never waits on this app.
    private var buttonTap: CFMachPort?
    private var buttonTapSource: CFRunLoopSource?
    /// Whether the activity log already has the line about the system
    /// pausing the blocking tap, once per tap installed, not per event.
    private var buttonTapTimeoutLogged = false

    // MARK: - Blocking a key's own action

    /// Keys (HID codes, never a modifier) whose own action is swallowed
    /// while a preset binds them with "Block the key's own action": W
    /// mapped to Up Arrow no longer also types W into the game's chat.
    /// Through an active tap of its own, like the mouse buttons, on the
    /// Accessibility permission the app's outputs already use.
    private(set) var blockedKeys: Set<Int> = []
    /// Virtual key codes whose press was swallowed and whose release has
    /// not come yet; the release (and any auto repeat) is swallowed only
    /// when its press was, so a key held across a preset switch lets go
    /// in the app that saw it go down.
    private var swallowedKeys: Set<Int> = []
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var keyTapTeardownPending = false
    private var keyTapTeardownToken = 0
    /// Keys pressed as a registered shortcut, so their release also stays
    /// out of the rows.
    private var shortcutKeysDown: Set<Int> = []
    private var keyTapTimeoutLogged = false

    /// Per blocked key (HID code) and per blocked mouse button, the held
    /// controls each blocking row waits for, from the engine. An empty list
    /// blocks whenever the preset runs; a chord blocks only while it is
    /// held, so J that fires only with Left Command held still types J.
    private var keyBlockChords: [Int: [[InputEvent]]] = [:]
    private var buttonBlockChords: [Int: [[InputEvent]]] = [:]
    /// The chord members held now, of those the event's flags cannot tell
    /// (a held key or mouse input; a modifier key comes from the flags
    /// here). The engine writes it on main after each change to what it
    /// holds, two main hops after the tap saw the change, so it answers
    /// only what the taps did not see themselves (`tapHeld`). It was a
    /// closure into the engine, which ran on main only.
    private var heldChordMembers: Set<InputEvent> = []
    /// Keys (input codes) the key tap saw go down and not yet up, and every
    /// key it saw go down or up, since it was made or last turned back on.
    /// Written by the tap under tapLock at the event, so a chord on A
    /// blocking W sees A the moment A went down, however busy main is. A
    /// key held since before the tap was made was never seen, and the
    /// engine answers for it, as before. Cleared with the tap, and when
    /// macOS turned it off (events passed it unseen meanwhile).
    private var tapKeysDown: Set<Int> = []
    private var tapKeysSeen: Set<Int> = []
    /// The same for the mouse buttons the button tap sees (2 and up).
    private var tapButtonsDown: Set<Int> = []
    private var tapButtonsSeen: Set<Int> = []
    /// The members of every chord list here that the engine answers for.
    /// Main only.
    private var chordMembersToWatch: [InputEvent] = []

    func setBlockChords(keys: [Int: [[InputEvent]]], buttons: [Int: [[InputEvent]]]) {
        locked {
            keyBlockChords = keys
            buttonBlockChords = buttons
            rebuildChordWatch()
        }
    }

    /// Main: the engine says which watched members are held. Free while no
    /// blocking row's chord has a held key or mouse input in it.
    func updateHeldChordMembers(_ isHeld: (InputEvent) -> Bool) {
        guard !chordMembersToWatch.isEmpty else { return }
        var held: Set<InputEvent> = []
        for member in chordMembersToWatch where isHeld(member) { held.insert(member) }
        locked { heldChordMembers = held }
    }

    /// Under tapLock, after a chord list changed. A member no longer listed
    /// reads as up; a new one reads as up until the engine answers.
    private func rebuildChordWatch() {
        var members: Set<InputEvent> = []
        for lists in [keyBlockChords, buttonBlockChords, keysRunningWhilePaused, buttonsRunningWhilePaused,
                      pointerRowKeys, pointerRowButtonChords] {
            for chords in lists.values {
                for chord in chords { for m in chord where Self.engineAnswers(m) { members.insert(m) } }
            }
        }
        chordMembersToWatch = Array(members)
        heldChordMembers.formIntersection(members)
    }

    /// Under tapLock. A chord member as the key or button tap saw it, at
    /// the event; nil when the taps cannot tell (a key or button not seen
    /// since the tap was made, another kind of mouse input, another device).
    private func tapHeld(_ input: InputEvent) -> Bool? {
        switch input.type {
        case .extKey:
            guard input.extDeviceID == nil || input.extDeviceID == Self.builtInKeyboardID,
                  tapKeysSeen.contains(input.index) else { return nil }
            return tapKeysDown.contains(input.index)
        case .extMouse:
            guard (input.extMouseKind ?? .button) == .button,
                  input.extDeviceID == nil || input.extDeviceID == Self.builtInMouseID,
                  tapButtonsSeen.contains(input.index) else { return nil }
            return tapButtonsDown.contains(input.index)
        default:
            return nil
        }
    }

    /// A member blockArmed hands the engine: a key that is no modifier and
    /// not fn (those it reads itself), or any mouse input. The engine
    /// answered anything else as up.
    private static func engineAnswers(_ m: InputEvent) -> Bool {
        m.type == .extKey ? !(224...231).contains(m.index) && m.index != KeyCodeMap.globeFnCode : m.type == .extMouse
    }

    /// Modifier keys a chord can hold that make a press a shortcut.
    private static let shortcutModifierCodes: Set<Int> = [224, 226, 227, 228, 230, 231]

    /// Whether a blocked key or button is held back now: some blocking row
    /// on it waits for nothing, or for a chord that is held. `shortcutChord`
    /// says a held chord includes Control, Option or Command, the only case
    /// a press with one of those is held back; `families` are those it
    /// holds, so a press that adds another is the Mac's and passes.
    /// Under tapLock.
    private func blockArmed(_ chords: [[InputEvent]]?, flags: CGEventFlags) -> (armed: Bool, shortcutChord: Bool, families: CGEventFlags, waitsForGlobe: Bool) {
        guard let chords, !chords.isEmpty else { return (true, false, [], false) }
        let raw = UInt(flags.rawValue)
        let own = InputSimulator.shared.ownModifierBitsSnapshot()
        var armed = false
        var shortcutChord = false
        var families: CGEventFlags = []
        var waitsForGlobe = false
        for chord in chords {
            let held = chord.allSatisfy { input in
                if input.type == .extKey, (224...231).contains(input.index),
                   let entry = Self.polledKeys.first(where: { $0.hid == input.index }) {
                    return Self.isDown(entry.vk, flags: raw, own: own)
                }
                // fn read from the key itself, as the Globe pass reads it.
                if input.type == .extKey, input.index == KeyCodeMap.globeFnCode { return Self.globeHeld() }
                return tapHeld(input) ?? heldChordMembers.contains(input)
            }
            guard held else { continue }
            armed = true
            if chord.contains(where: { $0.type == .extKey && $0.index == KeyCodeMap.globeFnCode }) { waitsForGlobe = true }
            for input in chord where input.type == .extKey && Self.shortcutModifierCodes.contains(input.index) {
                shortcutChord = true
                families.insert([224, 228].contains(input.index) ? .maskControl
                                : [226, 230].contains(input.index) ? .maskAlternate : .maskCommand)
            }
        }
        return (armed, shortcutChord, families, waitsForGlobe)
    }

    func setBlockedKeys(_ codes: Set<Int>) {
        // Modifiers and anything without a virtual key never block: a lost
        // Shift or Command would take the Mac's shortcuts with it.
        let safe = codes.filter { !(224...231).contains($0) && KeyCodeMap.hidToVirtualKeyCode[$0] != nil }
        guard safe != blockedKeys else { return }
        // One step with the taps' view of what was swallowed: a release on
        // the taps' thread in between found no teardown waiting for it.
        let waitForRelease: Bool = locked {
            blockedKeys = safe
            guard safe.isEmpty else {
                // A kept tap (its teardown was waiting on a held key) taken
                // up again: what it recorded may hold a release Secure Input
                // hid from it, so it starts over and the engine answers
                // until each key is seen again.
                if keyTapTeardownPending { tapKeysDown.removeAll(); tapKeysSeen.removeAll() }
                keyTapTeardownPending = false
                return false
            }
            // Held keys keep the tap until their release is swallowed too.
            guard !swallowedKeys.isEmpty, keyTap != nil else { return false }
            keyTapTeardownPending = true
            return true
        }
        if safe.isEmpty {
            if waitForRelease {
                keyTapTeardownToken &+= 1
                waitForSwallowedKeys(token: keyTapTeardownToken, tries: 0)
            } else {
                destroyKeyTap()
            }
            return
        }
        keyTapTeardownToken &+= 1
        if keyTap == nil { installKeyTap() }
        if keyTap != nil {
            ActivityLog.shared.info("Keyboard", "Blocking the own action of key(s) \(blockedKeys.sorted().map { KeyCodeMap.name(for: $0) }.joined(separator: ", ")) while this preset runs")
        }
    }

    /// Forces the teardown after 3 s, or once a swallowed key held longer
    /// is let go (a minute at most): gone sooner, the rest of a held key's
    /// repeats and its release reached the front app. A later start ends
    /// the wait, so an old timer cannot cut a new teardown short.
    private func waitForSwallowedKeys(token: Int, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 3 : 1)) { [weak self] in
            guard let self, token == self.keyTapTeardownToken, self.keyTapTeardownPending else { return }
            let swallowed = self.locked { self.swallowedKeys }
            let held = swallowed.contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
            if held, tries < 57 { self.waitForSwallowedKeys(token: token, tries: tries + 1) } else { self.finishKeyTapTeardown(force: true) }
        }
    }

    private func installKeyTap() {
        guard AXIsProcessTrusted() else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<ExternalInputDeviceService>.fromOpaque(userInfo).takeUnretainedValue()
            return service.handleKeyTapEvent(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            ActivityLog.shared.warning("Keyboard", "Could not block keys; they still work but also do their own action")
            locked { blockedKeys = [] }
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Known to the callback before its first event.
        locked {
            keyTap = tap
            keyTapTimeoutLogged = false
            tapKeysDown.removeAll()
            tapKeysSeen.removeAll()
        }
        keyTapSource = src
        Self.addToTapLoop(src)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// The key tap's callback: every key down and up on the Mac while a
    /// key is blocked. The event is fed to the keyboard inputs here (the
    /// NSEvent monitors leave keys to the tap meanwhile, so each press is
    /// reported once) and swallowed when its key is blocked. True to
    /// swallow. On the taps' thread: the decision under tapLock, the feed
    /// on main in the tap's order. `live` is false only for the bench,
    /// which makes the decision with no tap.
    fileprivate func handleKeyTapEvent(type: CGEventType, event: CGEvent, live: Bool = true) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let (tap, firstTimeout): (CFMachPort?, Bool) = locked {
                // Keys went down and up unseen while it was off.
                tapKeysDown.removeAll()
                tapKeysSeen.removeAll()
                guard let tap = keyTap else { return (nil, false) }
                let first = type == .tapDisabledByTimeout && !keyTapTimeoutLogged
                if first { keyTapTimeoutLogged = true }
                return (tap, first)
            }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if firstTimeout {
                    ActivityLog.shared.warning("Keyboard", "macOS paused the key block for being slow; a blocked key may have done its own action once. Blocking is back on.")
                }
            }
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }
        // The app's own synthesized keys always pass: W to Up Arrow must
        // not eat its own Up Arrow, and no output can loop back as input.
        if event.getIntegerValueField(.eventSourceUserData) == InputSimulator.ownEventMarker { return false }
        let vk = Int(event.getIntegerValueField(.keyboardEventKeycode))
        tapLock.lock()
        defer { tapLock.unlock() }
        // A tap removed on main while this event was on its way blocks
        // nothing, as no tap would.
        if live, keyTap == nil { return false }
        // A registered shortcut, a Shift-only one too (the recorder accepts
        // Shift F13, and the Emergency Stop may be it), passes and reaches
        // no row: the hot key takes it, as it does with no tap up.
        // On the press only: a repeat keeps the press's decision, or a held
        // swallowed key was handed to the front app when the chord's
        // modifiers went down after it.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           HotKeyCenter.shared.isShortcut(virtualKey: vk, flags: event.flags) {
            shortcutKeysDown.insert(vk)
            swallowedKeys.remove(vk)
            return false
        }
        if type == .keyUp, shortcutKeysDown.remove(vk) != nil { return false }
        // What the engine is fed below, seen here at the event: a chord
        // member on this key reads it at once (`tapHeld`). A repeat is no
        // new press, as the engine has it.
        let code = Self.inputCode(forVirtualKeyCode: vk)
        if type == .keyUp {
            tapKeysDown.remove(code)
            tapKeysSeen.insert(code)
        } else if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            tapKeysDown.insert(code)
            tapKeysSeen.insert(code)
        }
        #if canImport(AppKit)
        // Only while something reads the keyboard: the tap kept for a held
        // key's release after a stop fed every key on the Mac into the live
        // record with nothing to time them out, and the next start saw
        // phantom key ups. Asked on main, where the feed runs.
        if let copy = event.copy() {
            let sent = EventCopy(event: copy)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.keyboardConsumers.isEmpty, let ev = NSEvent(cgEvent: sent.event) else { return }
                self.handleKeyboardNSEvent(ev, fromTap: true)
            }
        }
        #endif
        if type == .keyDown {
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if repeating { return swallowedKeys.contains(vk) }
            // Paused for editing or suspended: the row sends nothing, so
            // the key keeps its own action rather than doing nothing.
            // Every press that passes forgets an earlier swallow of its key,
            // so a release missed while it was held cannot swallow the
            // release of this one and leave the key stuck in the front app.
            // Held back, only the chords of rows that run keep the block: a
            // plain W to Up Arrow passes while Shift W to Pause is swallowed.
            let chords: [[InputEvent]]?
            if blockingPaused {
                let pointer = pointerPassing ? pointerRowKeys[code] ?? [] : []
                let kept = (keysRunningWhilePaused[code] ?? []) + pointer
                guard !kept.isEmpty else { swallowedKeys.remove(vk); return false }
                chords = kept
            } else {
                chords = keyBlockChords[code]
            }
            guard !selfInFront, blockedKeys.contains(code) else { swallowedKeys.remove(vk); return false }
            // A row with a Second control blocks only while it is held.
            let arm = blockArmed(chords, flags: event.flags)
            guard arm.armed else { swallowedKeys.remove(vk); return false }
            // A press with Control, Option or Command is a shortcut (the
            // emergency stop, the preset shortcuts, the Mac's own) and
            // passes, unless the row itself waits for that modifier
            // (Command + J as a chord). Never the app's own shortcuts: the
            // tap runs ahead of their matching and would kill them silently.
            let held = Self.personShortcutFlags(event.flags, own: InputSimulator.shared.ownModifierBitsSnapshot())
            if !held.isEmpty {
                // Beyond what the chord holds it is the Mac's: Command
                // Option I with a row on Left Command and I.
                guard arm.shortcutChord, held.subtracting(arm.families).isEmpty else { swallowedKeys.remove(vk); return false }
            }
            // Globe A, Globe E. Read from the key: the fn flag rides on
            // every arrow and function key by itself. Typing keys only: fn
            // is how a MacBook types F5 and Page Up, which keep their Block,
            // and so does a row that waits for fn itself.
            if Self.isTypingKey(code), !arm.waitsForGlobe, Self.globeHeld() { swallowedKeys.remove(vk); return false }
            swallowedKeys.insert(vk)
            return true
        }
        guard swallowedKeys.remove(vk) != nil else { return false }
        if swallowedKeys.isEmpty && keyTapTeardownPending {
            DispatchQueue.main.async { [weak self] in self?.finishKeyTapTeardown(force: false) }
        }
        return true
    }

    #if DEBUG
    /// Tests only: one key event through the tap's decision, with the
    /// blocks set here and no tap installed. True when it would be swallowed.
    func debugKeyTap(down: Bool, virtualKey: Int, flags: CGEventFlags = [], autorepeat: Bool = false) -> Bool {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(virtualKey), keyDown: down) else { return false }
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
        return handleKeyTapEvent(type: down ? .keyDown : .keyUp, event: event, live: false)
    }
    /// Tests only: the same decision made on the taps' own thread while
    /// main waits, as a real tap makes it. Nil when no answer came within a
    /// second, which means the decision waited on main.
    func debugKeyTapOnTapThread(down: Bool, virtualKey: Int, flags: CGEventFlags = [], autorepeat: Bool = false) -> (swallowed: Bool, onMain: Bool)? {
        final class Answer: @unchecked Sendable { var value: (swallowed: Bool, onMain: Bool)? }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(Self.tapLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            answer.value = (debugKeyTap(down: down, virtualKey: virtualKey, flags: flags, autorepeat: autorepeat), Thread.isMainThread)
            done.signal()
        }
        CFRunLoopWakeUp(Self.tapLoop)
        guard done.wait(timeout: .now() + 1) == .success else { return nil }
        return answer.value
    }
    /// Tests only: the blocked keys and chords, with no tap made. What was
    /// swallowed is left as it is, so a case can see a release it forgets.
    /// `held`: the chord members the engine answers as held.
    func debugSetKeyBlocks(_ codes: Set<Int>, chords: [Int: [[InputEvent]]] = [:], paused: Bool = false, selfFront: Bool = false,
                           running: [Int: [[InputEvent]]] = [:], pointer: [Int: [[InputEvent]]] = [:], held: Set<InputEvent> = []) {
        locked {
            keysRunningWhilePaused = running
            pointerRowKeys = pointer
            blockedKeys = codes
            keyBlockChords = chords
            blockingPaused = paused
            selfInFront = selfFront
            rebuildChordWatch()
            heldChordMembers = held
            // Nothing seen by the tap yet: `held` answers, as the engine
            // does for a key held since before the tap was made.
            tapKeysDown = []
            tapKeysSeen = []
        }
    }
    /// Tests only: the key tap's whole state, taken before the cases and put
    /// back after, so a running preset keeps its block and its tap.
    struct DebugKeyBlockState {
        let running: [Int: [[InputEvent]]], blocked: Set<Int>, chords: [Int: [[InputEvent]]]
        let paused: Bool, selfFront: Bool, swallowed: Set<Int>, shortcuts: Set<Int>
        let pointer: [Int: [[InputEvent]]], passing: Bool, held: Set<InputEvent>
        let tapDown: Set<Int>, tapSeen: Set<Int>
    }
    func debugKeyBlockState() -> DebugKeyBlockState {
        locked {
            DebugKeyBlockState(running: keysRunningWhilePaused, blocked: blockedKeys, chords: keyBlockChords, paused: blockingPaused,
                               selfFront: selfInFront, swallowed: swallowedKeys, shortcuts: shortcutKeysDown,
                               pointer: pointerRowKeys, passing: pointerPassing, held: heldChordMembers,
                               tapDown: tapKeysDown, tapSeen: tapKeysSeen)
        }
    }
    func debugRestoreKeyBlocks(_ state: DebugKeyBlockState) {
        locked {
            keysRunningWhilePaused = state.running
            blockedKeys = state.blocked
            keyBlockChords = state.chords
            blockingPaused = state.paused
            selfInFront = state.selfFront
            swallowedKeys = state.swallowed
            shortcutKeysDown = state.shortcuts
            pointerRowKeys = state.pointer
            pointerPassing = state.passing
            rebuildChordWatch()
            heldChordMembers = state.held
            tapKeysDown = state.tapDown
            tapKeysSeen = state.tapSeen
        }
    }
    func debugClearSwallowed() {
        locked {
            swallowedKeys = []
            shortcutKeysDown = []
        }
    }
    #endif

    private func finishKeyTapTeardown(force: Bool) {
        let nothingHeld = locked { swallowedKeys.isEmpty }
        guard keyTapTeardownPending, blockedKeys.isEmpty, force || nothingHeld else { return }
        destroyKeyTap()
    }

    private func destroyKeyTap() {
        // Out of the callback's sight first: an event already on its way
        // then passes untouched instead of swallowing for a tap being removed.
        let tap: CFMachPort? = locked {
            let taken = keyTap
            keyTap = nil
            swallowedKeys.removeAll()
            tapKeysDown.removeAll()
            tapKeysSeen.removeAll()
            // A shortcut's key let go after the tap is gone (the Emergency Stop
            // on Shift F13 ends the block) never comes back here, and the next
            // plain press's release was taken for it and never reached the row.
            shortcutKeysDown.removeAll()
            keyTapTeardownPending = false
            return taken
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = keyTapSource { CFRunLoopRemoveSource(Self.tapLoop, src, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        keyTapSource = nil
    }

    /// Mouse buttons (2 and up; main and secondary click never) whose own
    /// action is swallowed while a preset binds them with "Block the
    /// button's own action". Set by the engine on start, cleared on stop.
    private(set) var blockedMouseButtons: Set<Int> = []

    /// Buttons whose press was swallowed and whose release has not come
    /// yet. A release is swallowed only when its press was, so stopping the
    /// preset mid-press does not let a bare release through, and a press
    /// made before blocking began still gets its release.
    private var swallowedPresses: Set<Int> = []
    /// The button tap outlives an empty blocked set until every swallowed
    /// press has had its release, or a few seconds pass.
    private var buttonTapTeardownPending = false
    private var buttonTapTeardownToken = 0

    /// True while the engine's outputs are paused (the editor is open) or
    /// suspended: the row sends nothing then, so the button keeps its own
    /// action rather than doing nothing at all. A row with a pointer output
    /// still sends it while pointer passthrough is on (in the editor, at
    /// the lock screen), so its button stays blocked then.
    private var blockingPaused = false
    /// Blocked keys whose rows run while outputs are held back (Pause or
    /// Resume Outputs, Next Preset under Only in these apps), with the
    /// chords of those rows: they stay blocked, or each press also did the
    /// key's own action; a row on the same key that does not run passes.
    private var keysRunningWhilePaused: [Int: [[InputEvent]]] = [:]
    /// The same for buttons (a side button on Pause or Resume Outputs),
    /// with the chords of those rows.
    private var buttonsRunningWhilePaused: [Int: [[InputEvent]]] = [:]
    /// Blocked keys and buttons whose rows send a click, pointer move or
    /// scroll, with the chords of those rows: held back while pointer
    /// outputs pass, and a row on the same key that sends nothing passes.
    private var pointerRowKeys: [Int: [[InputEvent]]] = [:]
    private var pointerRowButtonChords: [Int: [[InputEvent]]] = [:]
    func setBlockingPaused(_ paused: Bool, keeping running: [Int: [[InputEvent]]] = [:], buttons: [Int: [[InputEvent]]] = [:],
                           pointerKeys: [Int: [[InputEvent]]] = [:], pointerButtons: [Int: [[InputEvent]]] = [:]) {
        locked {
            blockingPaused = paused
            keysRunningWhilePaused = running
            buttonsRunningWhilePaused = buttons
            pointerRowKeys = pointerKeys
            pointerRowButtonChords = pointerButtons
            rebuildChordWatch()
        }
    }

    /// Control, Option and Command the person holds: a family whose only
    /// side down is one this app posted (a row holding Left Control) is the
    /// app's, so a blocked W under it is no shortcut. An event with no side
    /// bits for a family counts it, unless the app holds that family.
    nonisolated static func personShortcutFlags(_ flags: CGEventFlags, own: UInt) -> CGEventFlags {
        let raw = UInt(flags.rawValue)
        var held: CGEventFlags = []
        for (mask, sides) in [(CGEventFlags.maskControl, UInt(0x2001)), (.maskAlternate, 0x60), (.maskCommand, 0x18)]
        where flags.contains(mask) {
            if raw & sides == 0 ? own & sides == 0 : (raw & ~own) & sides != 0 { held.insert(mask) }
        }
        return held
    }

    /// Letters, digits and punctuation, the keys Globe shortcuts sit on (HID
    /// codes). Function and navigation keys are not: fn types those.
    private static func isTypingKey(_ code: Int) -> Bool {
        (4...39).contains(code) || (45...56).contains(code) || code == 100
    }

    private static func globeHeld() -> Bool {
        #if DEBUG
        if let fake = debugGlobeHeld { return fake }
        #endif
        return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Function))
    }
    #if DEBUG
    nonisolated(unsafe) static var debugGlobeHeld: Bool?
    #endif
    /// True while one of InputConfig's own windows is in front: every key
    /// and button keeps its own action there, so a WASD preset with Block
    /// on can still type a W into a name or the search field. Set by the
    /// engine with the wheel shaper's own flag; the taps read it under tapLock.
    private var selfInFront = false
    func setSelfInFront(_ front: Bool) { locked { selfInFront = front } }
    /// Blocked buttons whose rows send a click, pointer move or scroll.
    private var pointerRowButtons: Set<Int> = []
    /// Read on each blocked press: does the engine let pointer outputs
    /// through? Written by the engine on its pause edges and ticks. It was a
    /// closure into the engine, which ran on main only.
    private var pointerPassing = false
    func setPointerOutputsPassing(_ passing: Bool) { locked { pointerPassing = passing } }

    func setBlockedMouseButtons(_ buttons: Set<Int>, pointerRows: Set<Int> = []) {
        locked { pointerRowButtons = pointerRows }
        let safe = buttons.filter { $0 >= 2 && $0 <= 31 }
        guard safe != blockedMouseButtons else { return }
        let tapsChange = safe.isEmpty != blockedMouseButtons.isEmpty
        // One step with the taps' view of what was swallowed, as for keys.
        let waitForRelease: Bool = locked {
            blockedMouseButtons = safe
            guard safe.isEmpty, !swallowedPresses.isEmpty, buttonTap != nil else { buttonTapTeardownPending = false; return false }
            buttonTapTeardownPending = true
            return true
        }
        // A later start or stop owns the teardown: an old timer forced a
        // newer one early, and a held button's release went Back.
        buttonTapTeardownToken &+= 1
        if waitForRelease {
            let token = buttonTapTeardownToken
            // The tap sees every release, so the tail ends with it; this is
            // only the cap, as the key side's. At 3 s a button still held
            // sent its release on as a bare up, which went Back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, token == self.buttonTapTeardownToken else { return }
                self.finishButtonTapTeardown(force: true)
            }
            return
        }
        // The listen tap's mask depends on whether the button tap exists.
        // With no listen tap to rebuild (its make failed), a kept button
        // tap with nothing to block goes here, or it outlived its owner.
        if tapsChange, eventTap != nil {
            restartMouseMonitoring()
        } else if safe.isEmpty, buttonTap != nil {
            destroyButtonTap()
        }
        // Read back rather than `safe`: a blocking tap the system refused
        // cleared the set again and logged why.
        if !blockedMouseButtons.isEmpty {
            ActivityLog.shared.info("Mouse", "Blocking the own action of mouse button(s) \(blockedMouseButtons.sorted().map { String($0 + 1) }.joined(separator: ", ")) while this preset runs")
        }
    }

    /// Begin listening for system mouse events (buttons, scroll, movement)
    /// so the user can bind their mouse as an input source. Uses a
    /// listen-only CGEventTap, which needs only the Accessibility permission
    /// - mouse events, unlike keyboard events, do not require Input
    /// Monitoring, so this rides on the app's one approved permission. We
    /// never tap keyboard events. No-op until Accessibility is granted; call
    /// again after the user grants it.
    private func startMouseMonitoring() {
        if eventTap != nil { return }
        guard AXIsProcessTrusted() else { return }

        let otherButtons: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let blocking = !blockedMouseButtons.isEmpty
        // A button tap kept from the last preset (a blocked button still
        // held while the preset switched) is reused, not leaked beside a
        // second one: it is turned back on here, and one the system will
        // not enable is dropped before the mask below counts on it.
        if let bTap = buttonTap {
            CGEvent.tapEnable(tap: bTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: bTap) { destroyButtonTap() }
        }
        // A button tap kept past the end of blocking (a swallowed press
        // waiting for its release) still reports every middle and side
        // button it sees, so the listen tap leaves them to it meanwhile;
        // both taking them reported each press twice.
        let otherButtonsTapped = blocking || buttonTap != nil
        let movement = !movementConsumers.isEmpty
        let moves: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)
        // Pen tablets post their own event types next to the mouse ones;
        // they need no permission beyond the tap already running.
        let tablet: CGEventMask = (1 << CGEventType.tabletPointer.rawValue) | (1 << CGEventType.tabletProximity.rawValue)
        let mask: CGEventMask = tablet |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (otherButtonsTapped ? 0 : otherButtons) |
            (movement ? moves : 0) |
            (1 << CGEventType.scrollWheel.rawValue)

        // Capture-free C callback; `userInfo` carries the service instance.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo = userInfo {
                Unmanaged<ExternalInputDeviceService>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                    .handleMouseEvent(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Tap couldn't be created (Accessibility not effective yet, or
            // the sandbox refused it). Leave installed=false; the UI's
            // Accessibility banner guides the user.
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        locked { eventTap = tap }
        runLoopSource = src
        Self.addToTapLoop(src)
        CGEvent.tapEnable(tap: tap, enable: true)
        cgEventTapInstalled = true
        tapHasMovement = movement

        // Middle and side buttons through an active tap that can drop a
        // bound button's press. It still reports every press it sees. A
        // kept tap was checked above; one the system would not enable is
        // rebuilt here rather than left dead.
        if blocking, buttonTap == nil {
            let buttonCallback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<ExternalInputDeviceService>.fromOpaque(userInfo).takeUnretainedValue()
                // Reported only while something reads the mouse (asked on
                // main, where the feed runs): the tap kept after a stop for a
                // held button's release fed the live record with nothing to
                // time it out, as the key tap did. A tap the system turned off
                // is turned back on regardless.
                service.handleMouseEvent(type: type, event: event, fromButtonTap: true)
                return service.shouldBlock(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }
            if let bTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .defaultTap, eventsOfInterest: otherButtons,
                                            callback: buttonCallback,
                                            userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                let bSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, bTap, 0)
                locked {
                    buttonTap = bTap
                    buttonTapTimeoutLogged = false
                    tapButtonsDown.removeAll()
                    tapButtonsSeen.removeAll()
                }
                buttonTapSource = bSrc
                Self.addToTapLoop(bSrc)
                CGEvent.tapEnable(tap: bTap, enable: true)
            } else {
                // No active tap: the listen tap takes the buttons back so
                // they still bind; they just are not blocked.
                ActivityLog.shared.warning("Mouse", "Could not block mouse buttons; they still work but also do their own action")
                CGEvent.tapEnable(tap: tap, enable: false)
                CFRunLoopRemoveSource(Self.tapLoop, src, .commonModes)
                CFMachPortInvalidate(tap)
                locked {
                    eventTap = nil
                    blockedMouseButtons = []
                }
                runLoopSource = nil
                startMouseMonitoring()
                return
            }
        }
        if !devices.contains(where: { $0.id == Self.builtInMouseID }) {
            devices.append(Device(id: Self.builtInMouseID, kind: .mouse,
                                  vendorID: 0, productID: 0,
                                  vendorName: "System", productName: "Mouse",
                                  serialNumber: nil, bus: .unknown, locationID: 0))
        }

        // Force Touch pressure is delivered only to the LOCAL monitor: macOS
        // routes NSEventTypePressure through the frontmost app's responder
        // chain, so a global monitor never receives it (there is no public API
        // that reports another app's trackpad force). Force Touch bindings
        // therefore fire only while InputConfig's own window is frontmost; a
        // global-monitor registration here would be silently dead, so we don't
        // install one and don't imply the feature works over other apps.
        ensurePressureMetricsMonitor()
    }

    /// Install the LOCAL pressure monitor on demand. Separate from the
    /// engine-driven monitoring so UI gauges (the Cursor Regions map) can
    /// show live Force Touch metrics while the user presses over our own
    /// window, with no Accessibility requirement and no engine running.
    func ensurePressureMetricsMonitor() {
        #if canImport(AppKit)
        guard pressureLocalMonitor == nil else { return }
        pressureLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.pressure]
        ) { [weak self] ev in
            self?.handlePressureNSEvent(ev)
            return ev
        }
        #endif
    }

    #if canImport(AppKit)
    private func handlePressureNSEvent(_ ev: NSEvent) {
        let value = max(0, min(1, Float(ev.pressure)))
        let stage = ev.stage
        let e: Event = .pressureChanged(deviceID: Self.builtInMouseID, value: value, stage: stage)
        noteLive(e)
        events.send(e)
        // Publish for UI gauges only on meaningful change.
        let stageFlipped = (stage >= 2) != (trackpadPressureStage >= 2)
        if abs(value - trackpadPressure) > 0.02 || stageFlipped || (value == 0 && trackpadPressure != 0) {
            trackpadPressure = value
            trackpadPressureStage = stage
        }
    }
    #endif

    /// Stop the mouse tap. The local pressure monitor stays installed so
    /// in-window gauges keep working; there is no global one to tear down.
    /// Send a release for every held input under `prefix` ("ems ", "ekb ")
    /// before its monitor goes away, so the engine lets go of rows on it;
    /// cleared silently, a held key or button stayed held in the engine.
    private func releaseHeldLive(prefix: String) {
        for key in liveUntil.keys where key.hasPrefix(prefix) && liveUntil[key] == .distantFuture {
            let parts = key.split(separator: " ").map(String.init)
            let event: Event?
            if parts.count == 3, parts[0] == "ekb", let code = Int(parts[1]) {
                event = .keyUp(deviceID: parts[2], hidCode: code)
            } else if parts.count == 5, parts[0] == "ems", let b = Int(parts[2]), parts[1] == "button" {
                event = .mouseButtonUp(deviceID: parts[4], button: b)
            } else if parts.count == 5, parts[0] == "ems", parts[1] == "scrollGesture" {
                event = .scrollGesture(deviceID: parts[4], active: false)
            } else if parts.count == 5, parts[0] == "ems", parts[1] == "pressure" || parts[1] == "deepPress" {
                event = .pressureChanged(deviceID: parts[4], value: 0, stage: 0)
            } else if parts.count == 5, parts[0] == "ems", parts[1] == "penInRange" || parts[1] == "penPressure" {
                // The engine clears the pen's pressure and buttons on it.
                event = .tabletProximity(deviceID: parts[4], entering: false, eraser: false)
            } else {
                event = nil
            }
            if let event { noteLive(event); events.send(event) }
        }
    }

    /// `forRestart`: the tap is made again at once with a new mask, and
    /// the buttons still held keep their live entries and engine state. A
    /// release was synthesized for each of them here, with no press to
    /// follow, so a row held on a button let go in the middle of the hold
    /// whenever movement or blocking changed; the new tap still sees the
    /// real release.
    private func stopMouseMonitoring(forRestart: Bool = false) {
        guard eventTap != nil else { return }
        // Out of the callback's sight first, as destroyKeyTap does: a
        // timeout event in flight on the taps' thread re-enabled the old tap
        // and posted one more restart of the new one.
        let tap = locked { () -> CFMachPort? in let t = eventTap; eventTap = nil; return t }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(Self.tapLoop, src, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        // A blocked button still down when blocking ended (the preset
        // stopped mid-press) keeps its tap until it is let go, or its bare
        // release reached the front app (finishButtonTapTeardown).
        // Kept too while blocking is still wanted: this is a restart for a
        // new mask, and a held blocked button's release must stay blocked.
        if !(buttonTapTeardownPending && !locked({ swallowedPresses.isEmpty })), blockedMouseButtons.isEmpty {
            destroyButtonTap()
        }
        runLoopSource = nil
        cgEventTapInstalled = false
        // The device entry stays across a restart, so "System Mouse" is
        // not published as gone and back for a new mask.
        guard !forRestart else { return }
        finishMouseTeardown()
    }

    /// The part of stopping that a restart skips: the device entry, the
    /// held inputs and the scroll gesture state.
    private func finishMouseTeardown() {
        releaseHeldLive(prefix: "ems ")
        devices.removeAll { $0.id == Self.builtInMouseID }
        for k in liveUntil.keys where k.hasPrefix("ems ") { liveUntil.removeValue(forKey: k) }
        if scrollGesture != .none { scrollGesture = .none }
    }

    /// The tap made again with a new mask. When the new tap could not be
    /// made (the permission went away), the stop is completed as a real
    /// one, so no held input or device entry outlives the tap.
    private func restartMouseMonitoring() {
        stopMouseMonitoring(forRestart: true)
        startMouseMonitoring()
        if eventTap == nil { finishMouseTeardown() }
    }

    private func stopKeyboardMonitoring() {
        #if canImport(AppKit)
        if let m = keyboardGlobalMonitor { NSEvent.removeMonitor(m); keyboardGlobalMonitor = nil }
        if let m = keyboardLocalMonitor { NSEvent.removeMonitor(m); keyboardLocalMonitor = nil }
        #endif
        releaseHeldLive(prefix: "ekb ")
        if let tap = sysDefinedTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = sysDefinedSource { CFRunLoopRemoveSource(Self.tapLoop, src, .commonModes) }
        if let tap = sysDefinedTap { CFMachPortInvalidate(tap) }
        locked { sysDefinedTap = nil }
        sysDefinedSource = nil
        devices.removeAll { $0.id == Self.builtInKeyboardID }
        polledDown.removeAll()
        for k in liveUntil.keys where k.hasPrefix("ekb ") { liveUntil.removeValue(forKey: k) }
    }

    /// Stop everything, whoever holds it. Only for app termination.
    func stopMonitoring() {
        mouseConsumers.removeAll()
        keyboardConsumers.removeAll()
        locked { blockedKeys = [] }
        destroyKeyTap()
        applyMonitoring()
    }

    /// Tap callback body, on the taps' thread. Reads a CGEvent into what
    /// main needs and hands it over; main makes our device-agnostic `Event`
    /// and publishes it, in the taps' order. Skips events we synthesized
    /// ourselves so a mouse OUTPUT can't loop back as INPUT.
    fileprivate func handleMouseEvent(type: CGEventType, event: CGEvent, fromButtonTap: Bool = false) {
        // The system can disable a tap if it ever blocks; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let (listenTap, blockTap, firstTimeout): (CFMachPort?, CFMachPort?, Bool) = locked {
                let first = buttonTap != nil && type == .tapDisabledByTimeout && !buttonTapTimeoutLogged
                if first { buttonTapTimeoutLogged = true }
                // Buttons went down and up unseen while it was off.
                if fromButtonTap {
                    tapButtonsDown.removeAll()
                    tapButtonsSeen.removeAll()
                }
                return (eventTap, buttonTap, first)
            }
            if let tap = listenTap { CGEvent.tapEnable(tap: tap, enable: true) }
            if let tap = blockTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                // While the tap was off, a blocked button did its own action
                // once. Said once per tap, so a busy Mac does not fill the log.
                if firstTimeout {
                    ActivityLog.shared.warning("Mouse", "macOS paused the mouse button block for being slow; a blocked button may have done its own action once. Blocking is back on.")
                }
            }
            // A tap the system will not turn back on (the permission went
            // away) is rebuilt instead of staying dead.
            if let tap = listenTap, !CGEvent.tapIsEnabled(tap: tap) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.mouseConsumers.isEmpty {
                        self.stopMouseMonitoring()
                    } else {
                        self.restartMouseMonitoring()
                    }
                }
            }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == InputSimulator.ownEventMarker {
            return
        }
        guard let reading = Self.mouseReading(type: type, event: event) else { return }
        DispatchQueue.main.async { [weak self] in
            // A tap stopped meanwhile feeds nothing more (its stop let go of
            // what it held); a restart's new tap is up again by now.
            guard let self, fromButtonTap ? self.buttonTap != nil && !self.mouseConsumers.isEmpty
                                          : self.eventTap != nil else { return }
            self.feedMouse(reading)
        }
    }

    /// What a tap reads off a mouse event on its thread, for main.
    fileprivate enum MouseReading: Sendable {
        case down(button: Int, double: Bool)
        case up(button: Int)
        case move(dx: Int, dy: Int)
        case scroll(ScrollFields)
        case tabletPoint(pressure: Float, tiltX: Float, tiltY: Float, buttons: Int)
        case tabletProximity(entering: Bool, eraser: Bool)
    }

    fileprivate static func mouseReading(type: CGEventType, event: CGEvent) -> MouseReading? {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // macOS counts clicks itself; the second of a pair is a double.
            return .down(button: mouseButton(of: event, type: type),
                         double: event.getIntegerValueField(.mouseEventClickState) == 2)
        case .leftMouseUp:    return .up(button: 0)
        case .rightMouseUp:   return .up(button: 1)
        case .otherMouseUp:   return .up(button: mouseButton(of: event, type: type))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .move(dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
                         dy: Int(event.getIntegerValueField(.mouseEventDeltaY)))
        case .scrollWheel:
            return .scroll(ScrollFields(event))
        case .tabletPointer:
            let p = tabletPoint(of: event)
            return .tabletPoint(pressure: p.pressure, tiltX: p.tiltX, tiltY: p.tiltY, buttons: p.buttons)
        case .tabletProximity:
            let p = tabletProximity(of: event)
            return .tabletProximity(entering: p.entering, eraser: p.eraser)
        default:
            return nil
        }
    }

    /// One reading fed on main, as the tap callback fed it there before.
    private func feedMouse(_ reading: MouseReading) {
        let dev = Self.builtInMouseID
        let e: Event
        var also: Event? = nil
        switch reading {
        case .down(let button, let double):
            if button >= 5 {
                Self.noteUnfamiliar("Mouse", id: "button\(button)",
                    "Mouse button \(button + 1) pressed. It can be bound: Scan a mouse row and press it.")
            }
            e = .mouseButtonDown(deviceID: dev, button: button)
            if double { also = .mouseDoubleClick(deviceID: dev, button: button) }
        case .up(let button):
            e = .mouseButtonUp(deviceID: dev, button: button)
        case .move(let dx, let dy):
            e = .mouseMove(deviceID: dev, dx: dx, dy: dy)
        case .scroll(let fields):
            let delta = Self.scrollDeltas(of: fields, carry: &scrollCarry)
            e = .scroll(deviceID: dev, dx: delta.dx, dy: delta.dy)
            also = scrollGestureTransition(fields, dev: dev)
        case .tabletPoint(let pressure, let tiltX, let tiltY, let buttons):
            e = .tabletPoint(deviceID: Self.tabletID, pressure: pressure, tiltX: tiltX, tiltY: tiltY, buttons: buttons)
        case .tabletProximity(let entering, let eraser):
            e = .tabletProximity(deviceID: Self.tabletID, entering: entering, eraser: eraser)
        }
        if !cgEventTapReceivedAnyEvent { cgEventTapReceivedAnyEvent = true }
        noteLive(e)
        events.send(e)
        if let extra = also {
            noteLive(extra)
            events.send(extra)
        }
    }

    /// True for a press or release of a blocked button that a person made
    /// (the app's own synthesized clicks always pass through). On the
    /// taps' thread, under tapLock.
    fileprivate func shouldBlock(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .otherMouseDown || type == .otherMouseUp,
              event.getIntegerValueField(.eventSourceUserData) != InputSimulator.ownEventMarker else { return false }
        let button = Self.mouseButton(of: event, type: type)
        tapLock.lock()
        defer { tapLock.unlock() }
        // A tap removed on main while this event was on its way blocks
        // nothing, as no tap would.
        guard buttonTap != nil else { return false }
        // Seen at the event, for a chord that holds this button (`tapHeld`).
        if type == .otherMouseDown { tapButtonsDown.insert(button) } else { tapButtonsDown.remove(button) }
        tapButtonsSeen.insert(button)
        if type == .otherMouseDown {
            // Held back, only the chords of rows that run keep the block, as
            // for keys: a plain side button to Up Arrow passes while Shift
            // plus the button to Pause is swallowed.
            let chords: [[InputEvent]]?
            var paused = false
            if blockingPaused {
                let pointer = pointerPassing ? pointerRowButtonChords[button] ?? [] : []
                let kept = (buttonsRunningWhilePaused[button] ?? []) + pointer
                if kept.isEmpty { chords = nil; paused = true } else { chords = kept }
            } else {
                chords = buttonBlockChords[button]
            }
            // A row with a pointer output keeps its button blocked over
            // InputConfig's windows too, so the click it sends is the only one.
            let ownWindow = selfInFront && !pointerRowButtons.contains(button)
            guard !paused, !ownWindow, blockedMouseButtons.contains(button),
                  blockArmed(chords, flags: event.flags).armed else {
                // As with keys: a passed press forgets an earlier swallow.
                swallowedPresses.remove(button)
                return false
            }
            swallowedPresses.insert(button)
            return true
        }
        guard swallowedPresses.remove(button) != nil else { return false }
        if swallowedPresses.isEmpty && buttonTapTeardownPending {
            // Not from inside the tap's own callback.
            DispatchQueue.main.async { [weak self] in self?.finishButtonTapTeardown(force: false) }
        }
        return true
    }

    /// Drop the button tap once blocking ended and the last swallowed
    /// press got its release (or, forced, after the wait ran out).
    private func finishButtonTapTeardown(force: Bool) {
        let nothingHeld = locked { swallowedPresses.isEmpty }
        guard buttonTapTeardownPending, blockedMouseButtons.isEmpty,
              force || nothingHeld else { return }
        locked { buttonTapTeardownPending = false }
        if eventTap != nil {
            restartMouseMonitoring()
        } else {
            // Monitoring already stopped; only the kept button tap is left.
            destroyButtonTap()
        }
    }

    private func destroyButtonTap() {
        // Out of the callback's sight first, as the key tap's.
        let tap: CFMachPort? = locked {
            let taken = buttonTap
            buttonTap = nil
            swallowedPresses.removeAll()
            tapButtonsDown.removeAll()
            tapButtonsSeen.removeAll()
            buttonTapTeardownPending = false
            return taken
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = buttonTapSource { CFRunLoopRemoveSource(Self.tapLoop, src, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        buttonTapSource = nil
    }

    /// Which button a mouse event is for, numbered the way macOS numbers
    /// them: 0 main, 1 secondary, 2 middle, then every extra button up to 31.
    static func mouseButton(of event: CGEvent, type: CGEventType) -> Int {
        switch type {
        case .leftMouseDown, .leftMouseUp: return 0
        case .rightMouseDown, .rightMouseUp: return 1
        default: return Int(event.getIntegerValueField(.mouseEventButtonNumber))
        }
    }

    /// Leftover fractions of a step from continuous scrolls, per axis.
    private var scrollCarry: (x: Double, y: Double) = (0, 0)

    /// A scroll event's movement: dx from a tilt wheel or a sideways swipe,
    /// dy from the wheel itself. A notched wheel sends whole lines. A
    /// continuous scroll (trackpad, Magic Mouse, a free spinning wheel)
    /// sends points with `kCGScrollWheelEventIsContinuous` set and a line
    /// delta that is usually 0: about ten points make a line (CGEvent.h),
    /// so points are added up and the remainder carried to the next event,
    /// or a 3 point nudge and a 60 point flick both counted as one step.
    static func scrollDeltas(of event: CGEvent, carry: inout (x: Double, y: Double)) -> (dx: Int, dy: Int) {
        scrollDeltas(of: ScrollFields(event), carry: &carry)
    }

    static func scrollDeltas(of s: ScrollFields, carry: inout (x: Double, y: Double)) -> (dx: Int, dy: Int) {
        let dx = scrollSteps(line: s.lineX, point: s.pointX, continuous: s.continuous, carry: &carry.x)
        let dy = scrollSteps(line: s.lineY, point: s.pointY, continuous: s.continuous, carry: &carry.y)
        return (dx, dy)
    }

    /// A scroll event's fields, read on the taps' thread: the event itself
    /// is gone by the time main feeds it.
    struct ScrollFields: Sendable {
        let continuous: Bool
        let lineX: Int, pointX: Int, lineY: Int, pointY: Int
        let phase: Int64, momentum: Int64
        init(_ event: CGEvent) {
            continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            lineX = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            pointX = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            lineY = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            pointY = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        }
    }

    /// Steps for one axis of one scroll event; `carry` keeps the fraction.
    static func scrollSteps(line: Int, point: Int, continuous: Bool, carry: inout Double) -> Int {
        if continuous {
            carry += Double(point) / 10
            let steps = Int(carry.rounded(.towardZero))
            carry -= Double(steps)
            return steps
        }
        carry = 0
        if line != 0 { return line }
        return point > 0 ? 1 : (point < 0 ? -1 : 0)
    }

    /// Keys and buttons already noted this session, so an unusual one is
    /// logged on its first press and not on every press after.
    private static let unfamiliarLock = NSLock()
    nonisolated(unsafe) private static var unfamiliarSeen = Set<String>()

    /// Notes the first press of a key without a name, or of an extra mouse
    /// button, in the activity log. A saved report then shows exactly what
    /// an unusual keyboard or mouse sends. The input works either way.
    static func noteUnfamiliar(_ source: String, id: String, _ text: String) {
        unfamiliarLock.lock()
        let first = unfamiliarSeen.insert(id).inserted
        unfamiliarLock.unlock()
        if first { ActivityLog.shared.info(source, text) }
    }

    /// Reads the finger-scroll phases a trackpad or Magic Mouse stamps on
    /// its scroll events (a wheel stamps none) and turns them into the
    /// published gesture state plus a begin / end event when it changes.
    /// The fields hold CGScrollPhase (1 began, 2 changed, 4 ended,
    /// 8 canceled, 128 may begin) and CGMomentumScrollPhase (1 begin,
    /// 2 continue, 3 end) values, not NSEvent phase bits. Read as bits, an
    /// ended scroll stayed "fingers" and a momentum end turned the gesture
    /// back on, so a row on it stayed held until the next scroll.
    /// Cancels a delayed gesture end; see scrollGestureTransition.
    private var scrollEndToken = 0

    private func scrollGestureTransition(_ fields: ScrollFields, dev: String) -> Event? {
        let phase = fields.phase
        let momentum = fields.momentum
        let next: ScrollGesture
        if phase == 1 || phase == 2 || phase == 128 { next = .fingers }
        else if momentum == 1 || momentum == 2 { next = .momentum }
        else { next = .none }
        // Fingers lifted with no momentum yet: momentum may begin on the
        // next event, so the end waits a moment. Ending at once let a row
        // on the gesture let go and press again within one flick.
        if next == .none, phase == 4, momentum == 0, scrollGesture != .none {
            scrollEndToken &+= 1
            let token = scrollEndToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.scrollEndToken == token, self.scrollGesture != .none else { return }
                self.scrollGesture = .none
                let e: Event = .scrollGesture(deviceID: dev, active: false)
                self.noteLive(e)
                self.events.send(e)
            }
            return nil
        }
        scrollEndToken &+= 1
        guard next != scrollGesture else { return nil }
        let wasActive = scrollGesture != .none
        scrollGesture = next
        let isActive = next != .none
        return wasActive == isActive ? nil : .scrollGesture(deviceID: dev, active: isActive)
    }

    // MARK: - Keyboard input monitoring (Accessibility-gated, NSEvent)

    private var keyboardGlobalMonitor: Any?
    private var keyboardLocalMonitor: Any?
    private var pressureLocalMonitor: Any?
    /// Listen-only tap for NX_SYSDEFINED events (type 14): the media,
    /// volume, brightness, and keyboard-light keys. macOS handles those
    /// itself and hands them to the front app only, so the NSEvent
    /// monitors see them just while this window is in front. The tap sees
    /// them from any app. It is not a keyboard tap (no key down / up), so
    /// it rides on the Accessibility permission like the mouse tap.
    private var sysDefinedTap: CFMachPort?
    private var sysDefinedSource: CFRunLoopSource?

    /// Begin listening for Mac keyboard key presses so a `.extKey` binding
    /// can fire. Uses AppKit `NSEvent` monitors (the Accessibility API path),
    /// NOT a CGEventTap or IOHID keystroke stream, so it rides on the app's
    /// already-approved Accessibility permission and requests no new one. The
    /// global monitor delivers keys while another app (a game) is frontmost;
    /// the local monitor covers our own window. No-op until Accessibility is
    /// granted; call again after the user grants it.
    private func startKeyboardMonitoring() {
        #if canImport(AppKit)
        guard AXIsProcessTrusted() else { return }
        if keyboardGlobalMonitor == nil {
            keyboardGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]
            ) { [weak self] ev in
                self?.handleKeyboardNSEvent(ev)
            }
        }
        if keyboardLocalMonitor == nil {
            keyboardLocalMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]
            ) { [weak self] ev in
                self?.handleKeyboardNSEvent(ev)
                return ev
            }
        }
        if sysDefinedTap == nil {
            let callback: CGEventTapCallBack = { _, type, event, userInfo in
                if let userInfo = userInfo {
                    Unmanaged<ExternalInputDeviceService>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                        .handleSysDefinedCGEvent(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }
            if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: 1 << 14,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                locked { sysDefinedTap = tap }
                sysDefinedSource = src
                Self.addToTapLoop(src)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        if !devices.contains(where: { $0.id == Self.builtInKeyboardID }) {
            devices.append(Device(id: Self.builtInKeyboardID, kind: .keyboard,
                                  vendorID: 0, productID: 0,
                                  vendorName: "System", productName: "Keyboard",
                                  serialNumber: nil, bus: .unknown, locationID: 0))
        }
        #endif
    }

    /// NX_KEYTYPE_* -> the HID code the rest of the app stores for that key.
    /// Inverse of InputSimulator's specialKeyMap, so a media key scanned as
    /// INPUT lands on the same code a media key OUTPUT sends. Bluetooth
    /// headsets and hearing aids have no HID interface of their own; their
    /// button presses and tap gestures reach the Mac as AVRCP / HFP commands
    /// that macOS turns into these same aux-key events, so a hearing aid's
    /// double tap set to play / pause lands here as Play / Pause.
    static let hidUsageByNXKeyType: [Int: Int] = [
        // Measured on a 2024 MacBook keyboard: the brightness keys report
        // key types 3 and 2. The 0x90 / 0x91 pair is what older machines
        // sent and is kept for them.
        0x03: 71,   // Brightness Down
        0x02: 72,   // Brightness Up
        0x91: 71,   // Brightness Down (older keyboards)
        0x90: 72,   // Brightness Up (older keyboards)
        0x14: 307,  // Rewind
        0x10: 308,  // Play / Pause
        0x13: 309,  // Fast Forward
        0x11: 309,  // Next (Bluetooth headsets and hearing aids send this for "next")
        0x12: 307,  // Previous (the headset form of rewind)
        0x0E: 313,  // Eject
        0x15: 306,  // Keyboard illumination up
        0x16: 305,  // Keyboard illumination down
        0x07: 310,  // Mute
        0x00: 311,  // Volume Up
        0x01: 312,  // Volume Down
    ]

    /// Decodes an NSSystemDefined event into (HID code, pressed). Returns nil
    /// for anything that is not a recognized aux key press or release.
    static func mediaKey(from ev: NSEvent) -> (hid: Int, isDown: Bool)? {
        guard ev.type == .systemDefined else { return nil }
        // The eject key has its own subtype (IOLLEvent.h NX_SUBTYPE_EJECT_KEY,
        // 10) with no down or up in data1: it is a press, released by the
        // caller a moment later.
        if ev.subtype.rawValue == 10 { return (313, true) }
        guard ev.subtype.rawValue == 8 else { return nil }
        // Bit 0 of data1 is set on the autorepeat of a held key: the same
        // press again, not a new one.
        if ev.data1 & 0x1 != 0 { return nil }
        let keyType = (ev.data1 & 0xFFFF_0000) >> 16
        let state = (ev.data1 & 0x0000_FF00) >> 8
        guard state == 0x0A || state == 0x0B else { return nil }
        // A key type the table has no entry for still becomes an input,
        // "Special key N", so an unusual keyboard's extra keys can be bound.
        let hid = hidUsageByNXKeyType[keyType] ?? KeyCodeMap.unknownSystemKeyBase + keyType
        return (hid, state == 0x0A)
    }

    /// The NX_SYSDEFINED tap's callback, on the taps' thread: re-enable if
    /// the system paused the tap, then feed the event on main through the
    /// same decoder the NSEvent monitors use.
    fileprivate func handleSysDefinedCGEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = locked({ sysDefinedTap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        #if canImport(AppKit)
        guard let copy = event.copy() else { return }
        let sent = EventCopy(event: copy)
        DispatchQueue.main.async { [weak self] in
            // Stopped meanwhile: nothing reads it, and a key fed now stayed held.
            guard let self, self.sysDefinedTap != nil, let ev = NSEvent(cgEvent: sent.event) else { return }
            self.handleKeyboardNSEvent(ev, fromTap: true)
        }
        #endif
    }

    #if canImport(AppKit)
    private func handleKeyboardNSEvent(_ ev: NSEvent, fromTap: Bool = false) {
        if ev.type == .systemDefined {
            logRaw(String(format: "%@ sysDefined subtype=%d data1=0x%llX keyType=0x%llX state=0x%llX",
                          fromTap ? "tap" : "mon", ev.subtype.rawValue,
                          Int64(ev.data1), Int64((ev.data1 & 0xFFFF_0000) >> 16), Int64((ev.data1 & 0x0000_FF00) >> 8)))
        } else {
            logRaw(String(format: "%@ %@ keyCode=%d flags=0x%llX repeat=%d",
                          fromTap ? "tap" : "mon", ev.type == .keyDown ? "keyDown" : (ev.type == .keyUp ? "keyUp" : "flagsChanged"),
                          Int(ev.keyCode), UInt64(ev.modifierFlags.rawValue), ev.isARepeat ? 1 : 0))
        }
        // Skip keys we synthesized ourselves so a key OUTPUT can't loop back
        // in as INPUT (mirror of the mouse tap's own-event guard).
        if let cg = ev.cgEvent,
           cg.getIntegerValueField(.eventSourceUserData) == InputSimulator.ownEventMarker {
            return
        }
        // While the blocking tap is up it reports every key down and up
        // itself (it sees them first); the monitors' copies would double.
        if !fromTap, keyTap != nil, ev.type == .keyDown || ev.type == .keyUp { return }
        let dev = Self.builtInKeyboardID
        // Media / brightness keys arrive as NSSystemDefined with the key in
        // data1, not as a keyCode. While the tap is up it delivers them
        // from every app, this window included, so the monitors' copies
        // are dropped to avoid a double.
        if ev.type == .systemDefined {
            if !fromTap && sysDefinedTap != nil { return }
            guard let media = Self.mediaKey(from: ev) else { return }
            if media.isDown, media.hid >= KeyCodeMap.unknownSystemKeyBase {
                let type = media.hid - KeyCodeMap.unknownSystemKeyBase
                Self.noteUnfamiliar("Keyboard", id: "nx\(type)",
                    "Special key \(type) has no name in InputConfig. It still works as an input, shown as Special key \(type).")
            }
            let e: Event = media.isDown ? .keyDown(deviceID: dev, hidCode: media.hid)
                                        : .keyUp(deviceID: dev, hidCode: media.hid)
            if media.isDown, !receivedAnyKeyboardEvent { receivedAnyKeyboardEvent = true }
            noteLive(e)
            events.send(e)
            // Eject (subtype 10) carries no release of its own.
            if ev.subtype.rawValue == 10, media.isDown {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    let up: Event = .keyUp(deviceID: dev, hidCode: media.hid)
                    self.noteLive(up)
                    self.events.send(up)
                }
            }
            return
        }
        // Modifiers never send key down or key up; they send flagsChanged,
        // with the key in keyCode and its state in the flags. Each side of
        // a pair has its own device bit, Caps Lock reports its toggle, and
        // fn reports the function flag.
        // A side-specific modifier's edge is taken from the event when it
        // arrives, so Shift then A inside one poll tick reach the engine
        // in that order; the poll (pollKeys) reconciles what the monitors
        // missed and skips an edge already reported here. Caps Lock and
        // fn stay with the poll.
        if ev.type == .flagsChanged {
            noteModifierEdge(vk: CGKeyCode(ev.keyCode), flags: UInt(ev.modifierFlags.rawValue), dev: dev)
            return
        }
        let vk = Int(ev.keyCode)
        KeyboardLayoutService.noteKeyEvent()
        let hid = Self.inputCode(forVirtualKeyCode: vk)
        if hid >= KeyCodeMap.unknownKeyBase, ev.type == .keyDown, !ev.isARepeat {
            Self.noteUnfamiliar("Keyboard", id: "vk\(vk)",
                "Key code \(vk) has no name in InputConfig. It still works as an input, shown as Key code \(vk).")
        }
        switch ev.type {
        case .keyDown:
            if ev.isARepeat { return }
            if !receivedAnyKeyboardEvent { receivedAnyKeyboardEvent = true }
            let e: Event = .keyDown(deviceID: dev, hidCode: hid)
            noteLive(e); events.send(e)
        case .keyUp:
            let e: Event = .keyUp(deviceID: dev, hidCode: hid)
            noteLive(e); events.send(e)
        default:
            break
        }
    }
    #endif

    /// Which bit in `NSEvent.modifierFlags` says a given modifier key is
    /// down. The left and right keys of a pair have separate device bits
    /// (NX_DEVICE*KEYMASK), which is what lets the two be told apart.
    static let modifierDeviceBit: [Int: UInt] = [
        56: 0x0000_0002, 60: 0x0000_0004,   // left / right Shift
        59: 0x0000_0001, 62: 0x0000_2000,   // left / right Control
        58: 0x0000_0020, 61: 0x0000_0040,   // left / right Option
        55: 0x0000_0008, 54: 0x0000_0010,   // left / right Command
        57: 0x0001_0000,                    // Caps Lock (its toggle state)
        63: 0x0080_0000,                    // fn held
    ]

    /// Translate an AppKit / Carbon virtual key code (`NSEvent.keyCode`) into
    /// the USB HID Keyboard/Keypad usage code the rest of the app stores for
    /// keys (so a scanned key matches the same codes used by key OUTPUTS).
    /// Returns nil for keys with no standard HID usage. Table covers the full
    /// ANSI block, modifiers, function keys, arrows, and the keypad.
    static func hidUsage(forVirtualKeyCode vk: Int) -> Int? {
        Self.hidUsageByVirtualKey[vk]
    }

    /// The code a key press is stored under: its HID usage when the table
    /// knows the key, otherwise its macOS key code above
    /// `KeyCodeMap.unknownKeyBase`, so a key with no name is still bindable.
    static func inputCode(forVirtualKeyCode vk: Int) -> Int {
        hidUsage(forVirtualKeyCode: vk) ?? KeyCodeMap.unknownKeyBase + vk
    }

    /// Virtual-key to HID usage table, stored once. Building this dictionary
    /// inside the lookup function allocated a ~100-entry dict on every key
    /// event during typing.
    private static let hidUsageByVirtualKey: [Int: Int] = [
        // The Globe key tapped on its own. macOS reports it as a plain
        // keyDown at vk 179 carrying no fn flag (holding fn as a modifier
        // produces no key event at all), and it has no standard HID usage,
        // so it maps to the app's private code.
        179: KeyCodeMap.globeKeyCode,
        // The MacBook top row without fn (Mission Control, Launchpad,
        // Spotlight, Dictation, Focus) has these virtual keycodes, but
        // measured on macOS 26 none of them reaches an app as any event at
        // all without Input Monitoring; the mapping is kept for keyboards
        // that do send them as plain keys.
        160: 304, 131: 303, 177: KeyCodeMap.spotlightKeyCode,
        176: KeyCodeMap.dictationKeyCode, 178: KeyCodeMap.focusKeyCode,
        // Letters and number row.
            0: 4, 1: 22, 2: 7, 3: 9, 4: 11, 5: 10, 6: 29, 7: 27, 8: 6, 9: 25,
            11: 5, 12: 20, 13: 26, 14: 8, 15: 21, 16: 28, 17: 23,
            18: 30, 19: 31, 20: 32, 21: 33, 22: 35, 23: 34, 24: 46, 25: 38,
            26: 36, 27: 45, 28: 37, 29: 39, 30: 48, 31: 18, 32: 24, 33: 47,
            34: 12, 35: 19, 36: 40, 37: 15, 38: 13, 39: 52, 40: 14, 41: 51,
            42: 49, 43: 54, 44: 56, 45: 17, 46: 16, 47: 55, 48: 43, 49: 44,
            50: 53, 51: 42, 53: 41,
            // Modifiers. 54 is Right Command, which was missing entirely, so
            // the right-hand Command key could never be scanned or bound.
            54: 231, 55: 227, 56: 225, 57: 57, 58: 226, 59: 224,
            60: 229, 61: 230, 62: 228,
            // fn / Globe HELD as a modifier (the tapped form is 179 above).
            63: KeyCodeMap.globeFnCode,
            // Keypad.
            65: 99, 67: 85, 69: 87, 71: 83, 75: 84, 76: 88, 78: 86, 81: 103,
            82: 98, 83: 89, 84: 90, 85: 91, 86: 92, 87: 93, 88: 94, 89: 95,
            91: 96, 92: 97,
            // Function keys.
            96: 62, 97: 63, 98: 64, 99: 60, 100: 65, 101: 66, 103: 68,
            105: 104, 107: 105, 109: 67, 111: 69, 113: 106,
            // F16-F19 were absent, so those keys scanned as nothing at all.
            106: 107, 64: 108, 79: 109, 80: 110,
            // Navigation cluster.
            114: 73, 115: 74, 116: 75, 117: 76, 118: 61, 119: 77, 120: 59,
            121: 78, 122: 58, 123: 80, 124: 79, 125: 81, 126: 82,
            // Keys that scanned as nothing: F20, the PC Menu key, the ISO
            // section key, the Japanese keys, and keyboards that send volume
            // as plain keys (given the codes the media volume keys use).
            90: 111, 110: 101, 10: 100,
            93: 137, 94: 135, 95: 133, 102: 145, 104: 144,
            72: 311, 73: 312, 74: 310
    ]

    /// Stop the tap on app termination.
    func teardownForTermination() { stopMonitoring() }
}
