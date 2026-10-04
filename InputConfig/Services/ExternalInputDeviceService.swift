import Foundation
import Combine
import CoreGraphics
import ApplicationServices
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

        var deviceID: String {
            switch self {
            case .keyDown(let id, _), .keyUp(let id, _),
                 .mouseButtonDown(let id, _), .mouseButtonUp(let id, _),
                 .mouseMove(let id, _, _), .scroll(let id, _, _),
                 .pressureChanged(let id, _, _), .mouseDoubleClick(let id, _),
                 .scrollGesture(let id, _):
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
                    } else {
                        self.stopMouseMonitoring()
                        self.stopKeyboardMonitoring()
                        // The blocking tap too: kept, it came back after a
                        // re-grant possibly disabled, and nothing read the
                        // middle and side buttons.
                        self.destroyButtonTap()
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
        if eventTap != nil, tapHasMovement != !movementConsumers.isEmpty { stopMouseMonitoring() }
        if mouseConsumers.isEmpty { stopMouseMonitoring() } else { startMouseMonitoring() }
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
        }
    }

    /// Keys read by asking macOS for their physical state each tick rather
    /// than waiting for an event: the modifiers, which never arrive as
    /// flagsChanged here (measured), and the top-row keys macOS keeps to
    /// itself. `CGEventSource.keyState` answers for any key without Input
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

    /// 30 Hz: read the polled keys, drop what has timed out, and publish
    /// only when the set changed.
    private func publishLive() {
        pollKeys()
        reconcileHeld()
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
                noteLive(e); events.send(e)
            } else if parts.count == 5, parts[0] == "ems", parts[1] == "button", let b = Int(parts[2]),
                      let button = CGMouseButton(rawValue: UInt32(b)),
                      !CGEventSource.buttonState(.combinedSessionState, button: button) {
                let e: Event = .mouseButtonUp(deviceID: String(parts[4]), button: b)
                noteLive(e); events.send(e)
            }
        }
    }

    // MARK: - Public lookup (return empty / nil)

    func deviceName(for id: String) -> String? {
        devices.first(where: { $0.id == id })?.productName
    }

    func recentEventsFor(_ id: String) -> [LoggedEvent] { recentEvents[id] ?? [] }

    // MARK: - Mouse input monitoring (Accessibility-gated)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Active tap for middle and side button presses, installed only while
    /// a running preset blocks one of them (`blockedMouseButtons`). The
    /// listen-only tap above stops taking those events meanwhile, so each
    /// press is reported once, and cursor motion never waits on this app.
    private var buttonTap: CFMachPort?
    private var buttonTapSource: CFRunLoopSource?

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

    /// True while the engine's outputs are paused (the editor is open) or
    /// suspended: the row sends nothing then, so the button keeps its own
    /// action rather than doing nothing at all. A row with a pointer output
    /// still sends it while pointer passthrough is on (in the editor, at
    /// the lock screen), so its button stays blocked then.
    private var blockingPaused = false
    func setBlockingPaused(_ paused: Bool) { blockingPaused = paused }
    /// Blocked buttons whose rows send a click, pointer move or scroll.
    private var pointerRowButtons: Set<Int> = []
    /// Asked on each blocked press: does the engine let pointer outputs through?
    var pointerOutputsPassing: (() -> Bool)?

    func setBlockedMouseButtons(_ buttons: Set<Int>, pointerRows: Set<Int> = []) {
        pointerRowButtons = pointerRows
        let safe = buttons.filter { $0 >= 2 && $0 <= 31 }
        guard safe != blockedMouseButtons else { return }
        let tapsChange = safe.isEmpty != blockedMouseButtons.isEmpty
        blockedMouseButtons = safe
        if safe.isEmpty, !swallowedPresses.isEmpty, buttonTap != nil {
            buttonTapTeardownPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.finishButtonTapTeardown(force: true)
            }
            return
        }
        buttonTapTeardownPending = false
        // The listen tap's mask depends on whether the button tap exists.
        if tapsChange, eventTap != nil {
            stopMouseMonitoring()
            startMouseMonitoring()
        }
        if !safe.isEmpty {
            ActivityLog.shared.info("Mouse", "Blocking the own action of mouse button(s) \(safe.sorted().map { String($0 + 1) }.joined(separator: ", ")) while this preset runs")
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
        let movement = !movementConsumers.isEmpty
        let moves: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (blocking ? 0 : otherButtons) |
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
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = src
        cgEventTapInstalled = true
        tapHasMovement = movement

        // Middle and side buttons through an active tap that can drop a
        // bound button's press. It still reports every press it sees. One
        // kept from the last preset (a blocked button still held while the
        // preset switched) is reused, not leaked beside a second one.
        // A kept tap is turned back on; one the system will not enable is
        // rebuilt rather than left dead.
        if let bTap = buttonTap {
            CGEvent.tapEnable(tap: bTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: bTap) { destroyButtonTap() }
        }
        if blocking, buttonTap == nil {
            let buttonCallback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<ExternalInputDeviceService>.fromOpaque(userInfo).takeUnretainedValue()
                service.handleMouseEvent(type: type, event: event)
                return service.shouldBlock(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }
            if let bTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .defaultTap, eventsOfInterest: otherButtons,
                                            callback: buttonCallback,
                                            userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                let bSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, bTap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), bSrc, .commonModes)
                CGEvent.tapEnable(tap: bTap, enable: true)
                buttonTap = bTap
                buttonTapSource = bSrc
            } else {
                // No active tap: the listen tap takes the buttons back so
                // they still bind; they just are not blocked.
                ActivityLog.shared.warning("Mouse", "Could not block mouse buttons; they still work but also do their own action")
                CGEvent.tapEnable(tap: tap, enable: false)
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                CFMachPortInvalidate(tap)
                eventTap = nil
                runLoopSource = nil
                blockedMouseButtons = []
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
            } else {
                event = nil
            }
            if let event { noteLive(event); events.send(event) }
        }
    }

    private func stopMouseMonitoring() {
        guard eventTap != nil else { return }
        releaseHeldLive(prefix: "ems ")
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = eventTap { CFMachPortInvalidate(tap) }
        // A blocked button still down when blocking ended (the preset
        // stopped mid-press) keeps its tap until it is let go, or its bare
        // release reached the front app (finishButtonTapTeardown).
        // Kept too while blocking is still wanted: this is a restart for a
        // new mask, and a held blocked button's release must stay blocked.
        if !(buttonTapTeardownPending && !swallowedPresses.isEmpty), blockedMouseButtons.isEmpty {
            destroyButtonTap()
        }
        eventTap = nil
        runLoopSource = nil
        cgEventTapInstalled = false
        devices.removeAll { $0.id == Self.builtInMouseID }
        for k in liveUntil.keys where k.hasPrefix("ems ") { liveUntil.removeValue(forKey: k) }
        if scrollGesture != .none { scrollGesture = .none }
    }

    private func stopKeyboardMonitoring() {
        #if canImport(AppKit)
        if let m = keyboardGlobalMonitor { NSEvent.removeMonitor(m); keyboardGlobalMonitor = nil }
        if let m = keyboardLocalMonitor { NSEvent.removeMonitor(m); keyboardLocalMonitor = nil }
        #endif
        releaseHeldLive(prefix: "ekb ")
        if let tap = sysDefinedTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = sysDefinedSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let tap = sysDefinedTap { CFMachPortInvalidate(tap) }
        sysDefinedTap = nil
        sysDefinedSource = nil
        devices.removeAll { $0.id == Self.builtInKeyboardID }
        polledDown.removeAll()
        for k in liveUntil.keys where k.hasPrefix("ekb ") { liveUntil.removeValue(forKey: k) }
    }

    /// Stop everything, whoever holds it. Only for app termination.
    func stopMonitoring() {
        mouseConsumers.removeAll()
        keyboardConsumers.removeAll()
        applyMonitoring()
    }

    /// Tap callback body (runs on the main run loop). Translates a CGEvent
    /// into our device-agnostic `Event` and publishes it. Skips events we
    /// synthesized ourselves so a mouse OUTPUT can't loop back as INPUT.
    fileprivate func handleMouseEvent(type: CGEventType, event: CGEvent) {
        // The system can disable a tap if it ever blocks; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            if let tap = buttonTap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A tap the system will not turn back on (the permission went
            // away) is rebuilt instead of staying dead.
            if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.stopMouseMonitoring()
                    self.applyMonitoring()
                }
            }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == InputSimulator.ownEventMarker {
            return
        }
        let dev = Self.builtInMouseID
        let out: Event?
        var also: Event? = nil
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = Self.mouseButton(of: event, type: type)
            if button >= 5 {
                Self.noteUnfamiliar("Mouse", id: "button\(button)",
                    "Mouse button \(button + 1) pressed. It can be bound: Scan a mouse row and press it.")
            }
            out = .mouseButtonDown(deviceID: dev, button: button)
            // macOS counts clicks itself; the second of a pair is a double.
            if event.getIntegerValueField(.mouseEventClickState) == 2 {
                also = .mouseDoubleClick(deviceID: dev, button: button)
            }
        case .leftMouseUp:    out = .mouseButtonUp(deviceID: dev, button: 0)
        case .rightMouseUp:   out = .mouseButtonUp(deviceID: dev, button: 1)
        case .otherMouseUp:
            out = .mouseButtonUp(deviceID: dev, button: Self.mouseButton(of: event, type: type))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            out = .mouseMove(deviceID: dev,
                             dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
                             dy: Int(event.getIntegerValueField(.mouseEventDeltaY)))
        case .scrollWheel:
            let delta = Self.scrollDeltas(of: event)
            out = .scroll(deviceID: dev, dx: delta.dx, dy: delta.dy)
            also = scrollGestureTransition(event, dev: dev)
        default:
            out = nil
        }
        guard let e = out else { return }
        if !cgEventTapReceivedAnyEvent { cgEventTapReceivedAnyEvent = true }
        noteLive(e)
        events.send(e)
        if let extra = also {
            noteLive(extra)
            events.send(extra)
        }
    }

    /// True for a press or release of a blocked button that a person made
    /// (the app's own synthesized clicks always pass through).
    fileprivate func shouldBlock(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .otherMouseDown || type == .otherMouseUp,
              event.getIntegerValueField(.eventSourceUserData) != InputSimulator.ownEventMarker else { return false }
        let button = Self.mouseButton(of: event, type: type)
        if type == .otherMouseDown {
            let paused = blockingPaused
                && !(pointerRowButtons.contains(button) && (pointerOutputsPassing?() ?? false))
            guard !paused, blockedMouseButtons.contains(button) else { return false }
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
        guard buttonTapTeardownPending, blockedMouseButtons.isEmpty,
              force || swallowedPresses.isEmpty else { return }
        buttonTapTeardownPending = false
        if eventTap != nil {
            stopMouseMonitoring()
            startMouseMonitoring()
        } else {
            // Monitoring already stopped; only the kept button tap is left.
            destroyButtonTap()
        }
    }

    private func destroyButtonTap() {
        if let tap = buttonTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = buttonTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let tap = buttonTap { CFMachPortInvalidate(tap) }
        swallowedPresses.removeAll()
        buttonTapTeardownPending = false
        buttonTap = nil
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

    /// A scroll event's movement: dx from a tilt wheel or a sideways swipe,
    /// dy from the wheel itself.
    static func scrollDeltas(of event: CGEvent) -> (dx: Int, dy: Int) {
        (Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
         Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
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

    private func scrollGestureTransition(_ event: CGEvent, dev: String) -> Event? {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
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
                CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                sysDefinedTap = tap
                sysDefinedSource = src
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
        guard ev.type == .systemDefined, ev.subtype.rawValue == 8 else { return nil }
        let keyType = (ev.data1 & 0xFFFF_0000) >> 16
        let state = (ev.data1 & 0x0000_FF00) >> 8
        guard state == 0x0A || state == 0x0B else { return nil }
        // A key type the table has no entry for still becomes an input,
        // "Special key N", so an unusual keyboard's extra keys can be bound.
        let hid = hidUsageByNXKeyType[keyType] ?? KeyCodeMap.unknownSystemKeyBase + keyType
        return (hid, state == 0x0A)
    }

    /// The NX_SYSDEFINED tap's callback: re-enable if the system paused
    /// the tap, then feed the event through the same decoder the NSEvent
    /// monitors use.
    fileprivate func handleSysDefinedCGEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = sysDefinedTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        #if canImport(AppKit)
        guard let ev = NSEvent(cgEvent: event) else { return }
        handleKeyboardNSEvent(ev, fromTap: true)
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
            return
        }
        // Modifiers never send key down or key up; they send flagsChanged,
        // with the key in keyCode and its state in the flags. Each side of
        // a pair has its own device bit, Caps Lock reports its toggle, and
        // fn reports the function flag.
        // Modifiers are read by polling their key state (see pollKeys);
        // flagsChanged is logged for the record and otherwise ignored.
        if ev.type == .flagsChanged { return }
        let vk = Int(ev.keyCode)
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
