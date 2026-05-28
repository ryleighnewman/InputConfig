import Foundation
import Combine
import IOKit
import IOKit.hid
import CoreGraphics
import QuartzCore   // CACurrentMediaTime() for the log-flush throttle.
import AppKit       // NSWorkspace for sleep/wake notifications.

/// Enumerates HID keyboards and mice plugged into the system and streams
/// their raw input events so they can be used as **input sources** in the
/// binding pipeline - alongside game controllers.
///
/// ## Why HID (not a CGEventTap)?
///
/// Using `IOHIDManager` reads from physical devices at the HID layer. That
/// means we automatically get our **anti-loop** behaviour for free: when
/// `InputSimulator` posts a synthetic `CGEvent`, that event is injected at
/// the event-tap layer and never appears in IOHIDManager callbacks. So
/// "remap external key X → key X" can't echo back into the engine and
/// re-fire forever.
///
/// ## What the user sees
///
/// * Each detected device shows up in `devices` with a stable `id` derived
///   from vendor / product / serial / location. The ID survives reboots.
/// * Every key / button press, mouse motion delta, and scroll tick is
///   pushed through `events` (`PassthroughSubject`). The MappingEngine
///   subscribes when a preset is active.
/// * A small rolling press log (`recentEventsFor(_:)`) is exposed so the
///   Settings → Devices tab can show "what did you just press on which
///   device" without recording a full session.
///
/// ## Permissions
///
/// Sandboxed App Store builds need `com.apple.security.device.usb` and
/// `com.apple.security.device.bluetooth` in the entitlements (we already
/// have both for the existing controller code). The first time the
/// service opens any keyboard, macOS shows the Input Monitoring TCC
/// prompt; until the user grants it, value callbacks fire with empty
/// usage data. The detection list itself works without Input Monitoring.
/// **Not** `@MainActor`. The HID-layer callbacks fire from a private
/// dispatch queue at the rate of physical input - hundreds of times per
/// second when a mouse is moving. If this class were main-actor-isolated,
/// every event would have to hop to main, drowning the SwiftUI run loop
/// and producing a permanent beach ball. Instead the class is a regular
/// `ObservableObject`; `@Published` mutations are explicitly dispatched
/// to main via `DispatchQueue.main.async` only when needed (and only
/// for low-frequency, user-visible events).
final class ExternalInputDeviceService: ObservableObject, @unchecked Sendable {
    static let shared = ExternalInputDeviceService()

    /// Background dispatch queue the IOHIDManager runs on. Critical:
    /// scheduling HID callbacks on the main runloop drowns the UI in
    /// micro-motion events from any active mouse and freezes SwiftUI.
    /// All decoding happens here; we hop to main only for publishing.
    private static let hidQueue = DispatchQueue(label: "JoystickConfig.ExternalInputHID",
                                                qos: .userInitiated)

    // MARK: - Public types

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

        var deviceID: String {
            switch self {
            case .keyDown(let id, _), .keyUp(let id, _),
                 .mouseButtonDown(let id, _), .mouseButtonUp(let id, _),
                 .mouseMove(let id, _, _), .scroll(let id, _, _):
                return id
            }
        }
    }

    /// Tiny human-readable label shown in the live press log.
    struct LoggedEvent: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let label: String
    }

    // MARK: - Published state

    @Published private(set) var devices: [Device] = []
    /// Most recent press / motion entries per device, newest first.
    @Published private(set) var recentEvents: [String: [LoggedEvent]] = [:]
    /// True after at least one keyboard event arrived. If it stays false
    /// for several seconds despite a keyboard being plugged in, Input
    /// Monitoring is almost certainly not granted yet.
    @Published private(set) var receivedAnyKeyboardEvent = false

    /// Live "currently pressed" set keyed by InputEvent.serialized. Each
    /// real key / button press inserts BOTH the device-specific form
    /// ("ekb 4 builtin.keyboard") AND the "any device" form
    /// ("ekb 4 any") so binding rows configured for either target match.
    /// Mirrors `GameControllerService.rawActiveInputs` for the editor's
    /// binding-row highlight, which checks this set even when the
    /// mapping engine isn't running.
    @Published private(set) var rawActiveInputs: Set<String> = []
    private let rawActiveLock = NSLock()

    /// Subject every value callback writes to. The MappingEngine subscribes
    /// when a preset starts and unsubscribes on stop. PassthroughSubject's
    /// `send()` is documented as safe to call from any thread for a
    /// *single* publisher, but we have TWO sources (the HID background
    /// queue AND the CGEventTap main runloop) that could fire
    /// concurrently - e.g. a USB keyboard and the built-in trackpad at
    /// the same instant. We serialize through `sendLock` so the subject
    /// only ever sees one send call at a time.
    let events = PassthroughSubject<Event, Never>()
    private let sendLock = NSLock()

    /// Serialized wrapper around `events.send`. ALL event broadcasts go
    /// through here, no exceptions.
    fileprivate func sendEvent(_ event: Event) {
        sendLock.lock()
        events.send(event)
        sendLock.unlock()
        updateRawActiveInputs(from: event)
    }

    /// Translate an Event into one or two `InputEvent.serialized` keys
    /// and update `rawActiveInputs`. Inserted on down-edge events,
    /// removed on up-edge events. Mouse-motion / scroll events are
    /// ignored - they're transient deltas with no clear "off" state.
    private func updateRawActiveInputs(from event: Event) {
        let keys: (insert: [String], remove: [String])
        switch event {
        case .keyDown(let dev, let hid):
            keys = (["ekb \(hid) \(dev)", "ekb \(hid) any"], [])
        case .keyUp(let dev, let hid):
            keys = ([], ["ekb \(hid) \(dev)", "ekb \(hid) any"])
        case .mouseButtonDown(let dev, let button):
            keys = (["ems button \(button) + \(dev)",
                     "ems button \(button) + any"], [])
        case .mouseButtonUp(let dev, let button):
            keys = ([], ["ems button \(button) + \(dev)",
                         "ems button \(button) + any"])
        default:
            return
        }
        rawActiveLock.lock()
        // Mutate in place. Swift's CoW means the assignment is a refcount
        // bump until the first insert/remove that actually changes
        // anything; if every insert / remove is a no-op (e.g. repeated
        // keyDown before keyUp on the same scancode) we skip the
        // publish entirely. Without this gate, sustained typing fires
        // a main-thread dispatch per keystroke even when downstream
        // observers don't care about repeats.
        var set = rawActiveInputs
        var changed = false
        for k in keys.insert {
            if set.insert(k).inserted { changed = true }
        }
        for k in keys.remove {
            if set.remove(k) != nil { changed = true }
        }
        let snapshot: Set<String>? = changed ? set : nil
        rawActiveLock.unlock()
        if let snapshot = snapshot {
            DispatchQueue.main.async { [weak self] in
                self?.rawActiveInputs = snapshot
            }
        }
    }

    /// User-settable: when true, the built-in MacBook keyboard / trackpad
    /// is filtered out of detection. Persisted in UserDefaults.
    @Published var excludeBuiltInDevices: Bool {
        didSet {
            UserDefaults.standard.set(excludeBuiltInDevices,
                                      forKey: Self.excludeBuiltInKey)
            // Rebuild the visible list immediately.
            republishVisibleDevices()
        }
    }

    private static let excludeBuiltInKey = "JoystickConfig.externalInput.excludeBuiltIn"

    // MARK: - Internal state

    /// Raw set of every device we currently have open, keyed by their
    /// stable string ID. `devices` is filtered from this.
    private var allDevices: [String: Device] = [:]
    /// HID device pointers held so we keep the callback registrations
    /// alive. IOHIDDeviceRef is a CFType.
    /// Last raw keyboard "report" per device, used to diff key-up vs
    /// key-down from the boot-protocol style key array reports that some
    /// keyboards emit instead of per-key value changes.

    private var manager: IOHIDManager?

    /// CGEventTap that captures session-level keyboard / mouse events.
    /// This is the ONLY way a sandboxed app can read events from the
    /// MacBook's built-in keyboard and trackpad - `IOHIDManager` cannot
    /// see them. Synthetic events we emit via `InputSimulator` are
    /// tagged with `InputSimulator.ownEventMarker` and filtered here so
    /// outputs can never echo back as inputs.
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    /// Synthetic device IDs used for events captured via the CGEventTap.
    /// Surfaced as "Built-in Keyboard" and "Built-in Mouse / Trackpad"
    /// in the device list so users can target them explicitly. Bindings
    /// with `extDeviceID == nil` ("Any keyboard") still match too.
    static let builtInKeyboardID = "builtin.keyboard"
    static let builtInMouseID = "builtin.mouse"

    /// Becomes true after the first successful event arrives through the
    /// tap. Lets the diagnostics tell apart "tap registered but TCC not
    /// granted" from "tap is genuinely getting events".
    @Published private(set) var cgEventTapReceivedAnyEvent = false
    /// True iff `CGEvent.tapCreate` returned non-nil. False means Input
    /// Monitoring permission isn't granted (or the tap port creation
    /// failed for some other reason - extremely unusual).
    @Published private(set) var cgEventTapInstalled = false

    // MARK: - Init

    private init() {
        excludeBuiltInDevices = UserDefaults.standard.bool(forKey: Self.excludeBuiltInKey)
        start()
        installSleepWakeObservers()
    }

    /// Hook NSWorkspace's sleep / wake notifications so the CGEventTap
    /// gets re-enabled after the Mac comes back from sleep. macOS often
    /// flips the tap to a disabled state on wake without firing the
    /// .tapDisabledByTimeout event the callback handles, so without
    /// this observer the tap silently dies and every cursor-region +
    /// extKey binding stops firing until the app restarts.
    private func installSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
        nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    /// Called from .didWake / .screensDidWake. Re-enables the CGEventTap
    /// if it's still installed but possibly disabled. Cheap to call -
    /// CGEvent.tapEnable on an already-enabled tap is a no-op.
    private func handleWake() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("ExternalInputDeviceService: re-enabled CGEventTap after wake")
        } else if cgEventTapInstalled == false {
            // Tap was never installed (e.g. user granted permission
            // after launch). Try again now that the system is awake.
            installEventTap()
        }
    }

    private func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOOptionBits(kIOHIDOptionsTypeNone))

        // Match keyboards, mice, and keypads on the Generic Desktop page.
        let match: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keypad]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, match as CFArray)

        // Trampolines from C callbacks back into the singleton.
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let svc = Unmanaged<ExternalInputDeviceService>
                .fromOpaque(ctx).takeUnretainedValue()
            // Snapshot the immutable description on the HID queue and
            // ship just that Sendable value type to main. The IOHIDManager
            // retains the device internally while open, so we don't need
            // a separate retain on our side.
            let info = svc.describe(device)
            DispatchQueue.main.async {
                svc.handleDeviceAddedOnMain(info: info)
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let svc = Unmanaged<ExternalInputDeviceService>
                .fromOpaque(ctx).takeUnretainedValue()
            let id = ExternalInputDeviceService.stableIDForDevice(device)
            DispatchQueue.main.async {
                svc.handleDeviceRemovedOnMain(id: id)
            }
        }, context)

        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            let svc = Unmanaged<ExternalInputDeviceService>
                .fromOpaque(ctx).takeUnretainedValue()
            // Stay on the background HID queue. Decode the raw value into
            // an `Event`, broadcast it through the subject (thread-safe
            // for our publish-only use), and only hop to main for
            // discrete events that need to update the @Published log.
            // Mouse motion / scroll deltas SKIP the main-thread hop
            // entirely - they would otherwise flood SwiftUI at the rate
            // of physical input (hundreds of events per second) and
            // freeze the UI.
            let element = IOHIDValueGetElement(value)
            let usagePage = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            let integerValue = IOHIDValueGetIntegerValue(value)
            let device = IOHIDElementGetDevice(element)
            svc.processOnBackground(device: device,
                                    usagePage: usagePage,
                                    usage: usage,
                                    value: integerValue)
        }, context)

        // CRITICAL: HID callbacks must NOT run on the main runloop.
        // Mice emit hundreds of motion deltas per second; routing those
        // through `CFRunLoopGetMain()` starves SwiftUI and produces a
        // permanent beach ball. Use a dedicated background queue instead.
        IOHIDManagerSetDispatchQueue(mgr, Self.hidQueue)
        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            NSLog("ExternalInputDeviceService: IOHIDManagerOpen failed: \(openResult). Input Monitoring may not be granted yet.")
        }
        manager = mgr

        // Install the CGEventTap that lets us also see the built-in
        // MacBook keyboard / trackpad - IOHIDManager is blind to those
        // from a sandboxed app.
        installEventTap()
        // Synthesize the two built-in devices into the device list
        // unconditionally; whether events actually arrive depends on
        // the Input Monitoring permission state, which the diagnostics
        // can show separately.
        injectBuiltInDevices()
    }

    // MARK: - CGEventTap

    /// Install a session-level event tap that captures every keyboard +
    /// mouse event the OS sees and routes it through the same `events`
    /// subject the IOHIDManager path uses. Events tagged with
    /// `InputSimulator.ownEventMarker` are skipped to prevent output
    /// loops.
    private func installEventTap() {
        // Cover keyboard + mouse + scroll. Mouse motion is included so
        // bindings on built-in trackpad work, but the actual rate is
        // throttled by CGEventTap natively (one event per CGEventPost,
        // not per physical pixel).
        let mask: UInt64 =
              (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let svc = Unmanaged<ExternalInputDeviceService>.fromOpaque(refcon).takeUnretainedValue()
                // macOS auto-disables a session-level tap that exceeds
                // its per-event processing budget (~1s, e.g. during
                // sleep/wake or heavy load). Without re-enabling, the
                // tap silently dies and every cursor-region / extKey
                // binding stops firing until the app is restarted.
                // Both timeout AND user-input variants of the disable
                // event are recoverable - just call tapEnable again.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    svc.handleTapDisabled()
                    return Unmanaged.passUnretained(event)
                }
                _ = proxy  // silence unused-arg warning
                svc.handleCGEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            NSLog("ExternalInputDeviceService: CGEvent.tapCreate failed - Input Monitoring permission likely not granted")
            DispatchQueue.main.async { [weak self] in
                self?.cgEventTapInstalled = false
            }
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        DispatchQueue.main.async { [weak self] in
            self?.cgEventTapInstalled = true
        }
    }

    /// macOS disabled the event tap (timeout or user-input filter).
    /// Re-enable it from the callback context so the tap doesn't stay
    /// dead for the rest of the process lifetime.
    private func handleTapDisabled() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("ExternalInputDeviceService: CGEventTap was disabled by macOS; re-enabled")
    }

    /// Tear down the CGEventTap + IOHIDManager. Called on app termination
    /// from `AppState.gracefulShutdown` so the process doesn't leak its
    /// mach port + runloop source on exit. Mach ports survive process
    /// teardown briefly via the kernel resource cache; explicitly
    /// releasing them lets a re-launch grab a fresh slot immediately
    /// instead of waiting for the kernel to garbage-collect.
    func teardownForTermination() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
    }

    /// Called for every CGEvent the tap captures. Runs on the main run
    /// loop (same thread the tap was registered on).
    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        // Anti-loop: skip events we posted ourselves via `InputSimulator`.
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == InputSimulator.ownEventMarker { return }

        switch type {
        case .keyDown:
            let virtualCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let hid = Self.virtualToHID[virtualCode] else { return }
            sendEvent(.keyDown(deviceID: Self.builtInKeyboardID, hidCode: hid))
            appendLogOnMain(deviceID: Self.builtInKeyboardID, label: "key down \(hid)")
            // Only flip @Published flags on the FIRST true transition.
            // Re-assigning a `true` already-true value still publishes a
            // change notification and re-renders every observer once per
            // keystroke - at sustained typing that's hundreds of pointless
            // SwiftUI invalidations per second.
            if !cgEventTapReceivedAnyEvent { cgEventTapReceivedAnyEvent = true }
            if !receivedAnyKeyboardEvent { receivedAnyKeyboardEvent = true }

        case .keyUp:
            let virtualCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let hid = Self.virtualToHID[virtualCode] else { return }
            sendEvent(.keyUp(deviceID: Self.builtInKeyboardID, hidCode: hid))
            appendLogOnMain(deviceID: Self.builtInKeyboardID, label: "key up \(hid)")

        case .leftMouseDown:
            sendEvent(.mouseButtonDown(deviceID: Self.builtInMouseID, button: 1))
            appendLogOnMain(deviceID: Self.builtInMouseID, label: "btn 1 down")
        case .leftMouseUp:
            sendEvent(.mouseButtonUp(deviceID: Self.builtInMouseID, button: 1))
            appendLogOnMain(deviceID: Self.builtInMouseID, label: "btn 1 up")
        case .rightMouseDown:
            sendEvent(.mouseButtonDown(deviceID: Self.builtInMouseID, button: 2))
            appendLogOnMain(deviceID: Self.builtInMouseID, label: "btn 2 down")
        case .rightMouseUp:
            sendEvent(.mouseButtonUp(deviceID: Self.builtInMouseID, button: 2))
            appendLogOnMain(deviceID: Self.builtInMouseID, label: "btn 2 up")
        case .otherMouseDown:
            let n = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
            sendEvent(.mouseButtonDown(deviceID: Self.builtInMouseID, button: n))
            appendLogOnMain(deviceID: Self.builtInMouseID, label: "btn \(n) down")
        case .otherMouseUp:
            let n = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
            sendEvent(.mouseButtonUp(deviceID: Self.builtInMouseID, button: n))
            appendLogOnMain(deviceID: Self.builtInMouseID, label: "btn \(n) up")

        case .mouseMoved:
            let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
            if dx != 0 || dy != 0 {
                sendEvent(.mouseMove(deviceID: Self.builtInMouseID, dx: dx, dy: dy))
            }
            // Feed the absolute cursor position into the cursor-region
            // service so any active `.cursorRegion` binding can be
            // evaluated on the next 120 Hz poll. The tap callback runs
            // on the main runloop (we added the source to
            // CFRunLoopGetMain), so it IS the main actor - assertIsolated
            // tells Swift's actor system that without an async hop.
            let location = event.location
            MainActor.assumeIsolated {
                CursorRegionService.shared.updateFromCGEventLocation(location)
            }

        case .scrollWheel:
            let dy = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let dx = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            if dx != 0 || dy != 0 {
                sendEvent(.scroll(deviceID: Self.builtInMouseID, dx: dx, dy: dy))
            }

        default:
            break
        }
    }

    private func appendLogOnMain(deviceID: String, label: String) {
        // Already on main here; just call the existing log appender.
        appendLog(deviceID: deviceID, label: label)
    }

    /// Adds synthetic Device entries for the built-in keyboard and mouse
    /// so bindings can target them explicitly. The "Hide built-in" toggle
    /// still filters them out of the visible list, but they remain
    /// addressable via their stable IDs.
    private func injectBuiltInDevices() {
        let keyboard = Device(
            id: Self.builtInKeyboardID,
            kind: .keyboard,
            vendorID: 0x05AC,
            productID: 0,
            vendorName: "Apple",
            productName: "Built-in Keyboard",
            serialNumber: nil,
            bus: .builtIn,
            locationID: 0
        )
        let mouse = Device(
            id: Self.builtInMouseID,
            kind: .mouse,
            vendorID: 0x05AC,
            productID: 0,
            vendorName: "Apple",
            productName: "Built-in Mouse / Trackpad",
            serialNumber: nil,
            bus: .builtIn,
            locationID: 0
        )
        allDevices[keyboard.id] = keyboard
        allDevices[mouse.id] = mouse
        Self.hidQueue.async {
            Self.bgDeviceCache[keyboard.id] = (kind: keyboard.kind, id: keyboard.id)
            Self.bgDeviceCache[mouse.id] = (kind: mouse.kind, id: mouse.id)
        }
        republishVisibleDevices()
    }

    /// macOS virtual key code → HID Keyboard/Keypad usage. Built once
    /// from the existing `KeyCodeMap.hidToVirtualKeyCode` table.
    nonisolated static let virtualToHID: [Int: Int] = {
        var m: [Int: Int] = [:]
        for (hid, virt) in KeyCodeMap.hidToVirtualKeyCode {
            m[virt] = hid
        }
        return m
    }()

    // MARK: - Device lifecycle

    /// Main-thread state mutation for a newly-added device.
    private func handleDeviceAddedOnMain(info: Device) {
        allDevices[info.id] = info
        // Mirror just (kind, id) into the background cache so the HID
        // queue can look up the device without touching main state.
        Self.hidQueue.async {
            Self.bgDeviceCache[info.id] = (kind: info.kind, id: info.id)
        }
        republishVisibleDevices()
    }

    private func handleDeviceRemovedOnMain(id: String) {
        allDevices.removeValue(forKey: id)
        recentEvents.removeValue(forKey: id)
        Self.hidQueue.async {
            Self.bgDeviceCache.removeValue(forKey: id)
        }
        republishVisibleDevices()
    }

    private func republishVisibleDevices() {
        var list: [Device] = []
        for (_, d) in allDevices {
            if excludeBuiltInDevices && d.bus == .builtIn { continue }
            list.append(d)
        }
        list.sort { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.productName < rhs.productName
        }
        devices = list
    }

    // MARK: - Value handling (background queue)

    /// Background-queue thread-safe lookup of device kind + id by IOHIDDevice.
    /// We snapshot the description once at device-added time so the
    /// background path doesn't need to read `allDevices` (which lives on
    /// main). The snapshot map is protected by the HID queue's serial
    /// nature: all reads/writes happen from the same queue.
    nonisolated(unsafe) private static var bgDeviceCache: [String: (kind: Kind, id: String)] = [:]

    /// Decode a raw HID value into an `Event` on the background queue
    /// and broadcast it. Discrete events (key / button down or up) hop
    /// to main to update the @Published log. Continuous events (mouse
    /// motion, scroll) skip the main-thread hop entirely - they're sent
    /// only through the events subject so the MappingEngine can read
    /// them, but they never trigger SwiftUI invalidation.
    nonisolated private func processOnBackground(device: IOHIDDevice,
                                                 usagePage: Int,
                                                 usage: Int,
                                                 value: Int) {
        let id = Self.stableIDForDevice(device)
        guard let info = Self.bgDeviceCache[id] else { return }

        switch info.kind {
        case .keyboard, .keypad:
            guard usagePage == kHIDPage_KeyboardOrKeypad else { return }
            if value == 1 {
                sendEvent(.keyDown(deviceID: id, hidCode: usage))
                let label = "key down \(usage)"
                DispatchQueue.main.async { [weak self] in
                    self?.appendLog(deviceID: id, label: label)
                    // Only publish a change on the FIRST true transition;
                    // re-assigning `true` on every keystroke triggers a
                    // SwiftUI invalidation storm for any view observing this.
                    if let s = self, !s.receivedAnyKeyboardEvent {
                        s.receivedAnyKeyboardEvent = true
                    }
                }
            } else {
                sendEvent(.keyUp(deviceID: id, hidCode: usage))
                let label = "key up \(usage)"
                DispatchQueue.main.async { [weak self] in
                    self?.appendLog(deviceID: id, label: label)
                }
            }

        case .mouse:
            switch usagePage {
            case kHIDPage_Button:
                // Discrete - update log on main.
                if value == 1 {
                    sendEvent(.mouseButtonDown(deviceID: id, button: usage))
                    let label = "btn \(usage) down"
                    DispatchQueue.main.async { [weak self] in
                        self?.appendLog(deviceID: id, label: label)
                    }
                } else {
                    sendEvent(.mouseButtonUp(deviceID: id, button: usage))
                    let label = "btn \(usage) up"
                    DispatchQueue.main.async { [weak self] in
                        self?.appendLog(deviceID: id, label: label)
                    }
                }
            case kHIDPage_GenericDesktop:
                // Continuous - subject only, no main-thread hop.
                switch usage {
                case kHIDUsage_GD_X where value != 0:
                    sendEvent(.mouseMove(deviceID: id, dx: value, dy: 0))
                case kHIDUsage_GD_Y where value != 0:
                    sendEvent(.mouseMove(deviceID: id, dx: 0, dy: value))
                case kHIDUsage_GD_Wheel where value != 0:
                    sendEvent(.scroll(deviceID: id, dx: 0, dy: value))
                default:
                    break
                }
            default:
                break
            }
        }
    }

    /// Static stable-ID computation that's safe to call from any queue
    /// (CFTypeRef property reads are thread-safe).
    nonisolated private static func stableIDForDevice(_ device: IOHIDDevice) -> String {
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString)
                      as? Int) ?? 0
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString)
                       as? Int) ?? 0
        if let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString)
                        as? String,
           !serial.isEmpty {
            return "v\(vendor)-p\(product)-s\(serial)"
        }
        let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString)
                        as? Int) ?? 0
        return "v\(vendor)-p\(product)-l\(location)"
    }

    /// Pending log additions per device. The hot CGEventTap callback
    /// dumps a LoggedEvent in here without paying the @Published
    /// republish cost; a 5 Hz timer flushes into `recentEvents`.
    private var pendingLog: [String: [LoggedEvent]] = [:]
    private var pendingLogFlushAt: CFTimeInterval = 0

    private func appendLog(deviceID: String, label: String) {
        var entries = pendingLog[deviceID] ?? recentEvents[deviceID] ?? []
        entries.insert(LoggedEvent(timestamp: Date(), label: label), at: 0)
        if entries.count > 10 { entries.removeLast(entries.count - 10) }
        pendingLog[deviceID] = entries

        // Throttle to 5 Hz - at sustained typing speed we'd otherwise
        // fire a @Published republish per keystroke (~80 ms keypress =
        // 12.5 Hz baseline). The Settings → Devices recent-events
        // panel only updates 5x/sec, which is plenty visually.
        let now = CACurrentMediaTime()
        if now - pendingLogFlushAt > 0.2 {
            pendingLogFlushAt = now
            // Take ownership of the buffer, drop the lock implicitly,
            // then publish on main. Skips entirely when nothing changed.
            let toPublish = pendingLog
            pendingLog.removeAll(keepingCapacity: true)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                for (id, entries) in toPublish {
                    self.recentEvents[id] = entries
                }
            }
        }
    }

    // MARK: - Public lookup

    func deviceName(for id: String) -> String? {
        allDevices[id]?.productName
    }

    func recentEventsFor(_ id: String) -> [LoggedEvent] {
        recentEvents[id] ?? []
    }

    // MARK: - HID introspection helpers

    private func describe(_ device: IOHIDDevice) -> Device {
        let id = stableID(for: device)
        let kind = detectedKind(of: device) ?? .keyboard
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString)
                      as? Int) ?? 0
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString)
                       as? Int) ?? 0
        let manuf = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString)
                     as? String) ?? ""
        let prod = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)
                    as? String) ?? "HID device"
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString)
                     as? String
        let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString)
                        as? Int) ?? 0
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString)
                         as? String) ?? ""
        let bus: Bus
        switch transport.lowercased() {
        case "usb":       bus = .usb
        case "bluetooth": bus = .bluetooth
        case "spi", "fifo": bus = .builtIn
        default:          bus = .unknown
        }
        return Device(id: id,
                      kind: kind,
                      vendorID: vendor,
                      productID: product,
                      vendorName: manuf,
                      productName: prod,
                      serialNumber: serial,
                      bus: bus,
                      locationID: location)
    }

    /// Returns a stable, reboot-resistant identifier for the device.
    /// Prefers serial number when available; falls back to a deterministic
    /// hash of vendor / product / location.
    private func stableID(for device: IOHIDDevice) -> String {
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString)
                      as? Int) ?? 0
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString)
                       as? Int) ?? 0
        if let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString)
                        as? String,
           !serial.isEmpty {
            return "v\(vendor)-p\(product)-s\(serial)"
        }
        let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString)
                        as? Int) ?? 0
        return "v\(vendor)-p\(product)-l\(location)"
    }

    private func detectedKind(of device: IOHIDDevice) -> Kind? {
        if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop),
                                 UInt32(kHIDUsage_GD_Keyboard)) {
            return .keyboard
        }
        if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop),
                                 UInt32(kHIDUsage_GD_Mouse)) {
            return .mouse
        }
        if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop),
                                 UInt32(kHIDUsage_GD_Keypad)) {
            return .keypad
        }
        return nil
    }
}
