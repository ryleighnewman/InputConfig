import Foundation
import IOKit
import IOKit.hid
import Combine
import GameController

/// Information about an 8BitDo controller detected at the HID level.
struct EightBitDoDevice: Identifiable, Hashable {
    let id: UInt64       // location ID (unique per physical device)
    let productID: Int32
    let productName: String
    let transport: String  // "USB", "Bluetooth", etc.
    let mode: EightBitDoMode
}

/// The connection mode an 8BitDo controller appears to be running in.
/// 8BitDo reuses product IDs across models and modes (0x6000-0x6012 are
/// D-input or Steam mode identities, 0x3xxx are plain HID dongles, 0x2002
/// is an Xbox-type identity), so the product ID says little. What matters
/// on a Mac is whether GameController lists the controller: one that
/// GameController does not list gets the mode hint, and its name refines
/// the hint when it spells out a mode.
///
/// On macOS:
///   - apple/MFi mode is fully supported through the GameController framework
///   - switch mode is partially supported (as a Nintendo Switch controller)
///   - xinput and dinput modes are recognized as HID devices but the
///     GameController framework will not see them
///   - macMode is the only one that exposes adaptive triggers, haptics, and
///     the full extended gamepad profile
enum EightBitDoMode: String {
    case apple = "Apple/MFi"       // Mode switch A
    case nintendoSwitch = "Switch" // Mode switch S
    case xinput = "XInput"         // Mode switch X
    case dinput = "DInput"         // Mode switch D
    case android = "Android"       // Android mode
    /// Seen on the bus but not listed by GameController, mode not named.
    case notSeenByGameController = "a non-Apple"
    case unknown = "Unknown"

    var supportedByMacOS: Bool {
        switch self {
        case .apple, .nintendoSwitch: return true
        default: return false
        }
    }
}

/// Watches IOKit for 8BitDo controllers and reports their mode.
/// This complements `GameControllerService` (which uses Apple's
/// GameController framework). If an 8BitDo controller is connected
/// but does not appear in `GameControllerService.connectedControllers`,
/// it is almost certainly in a mode the framework does not support.
@MainActor
final class EightBitDoDetector: ObservableObject {
    @Published private(set) var detectedDevices: [EightBitDoDevice] = []

    /// 8BitDo's official USB vendor ID.
    static let vendorID: Int32 = 0x2DC8

    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "com.inputconfig.8bitdo")
    private var rescanTimer: Timer?
    private var gcObservers: [NSObjectProtocol] = []

    #if DEBUG
    /// Marketing capture: an 8BitDo pad in the given mode
    /// (`post inputconfig.debug.fake8bitdo "XInput"`; empty removes it).
    private var debugFake: EightBitDoDevice?
    private var debugObserver: NSObjectProtocol?
    #endif

    init() {
        #if DEBUG
        debugObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("inputconfig.debug.fake8bitdo"), object: nil, queue: .main) { [weak self] note in
            let raw = (note.object as? String) ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                let mode = EightBitDoMode(rawValue: raw)
                self.debugFake = mode.map {
                    EightBitDoDevice(id: 0xFA4E_8B1D, productID: 0x6012, productName: "8BitDo Pro 2", transport: "USB", mode: $0)
                }
                self.rescan()
            }
        }
        #endif
        setupManager()
        startPolling()
        // GameController lists a controller a moment after IOKit reports
        // it, and drops it on its own schedule, so look again whenever
        // its list changes.
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            gcObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescan() }
            })
        }
    }

    // MARK: - Setup

    private func setupManager() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else { return }

        // Gamepads only (joystick, gamepad, multi-axis): 8BitDo also makes
        // keyboards, numpads and mice, which have no mode switch and kept
        // the "flip the switch to A" banner up for good.
        let matches: [[String: Any]] = [4, 5, 8].map { usage in
            [kIOHIDVendorIDKey as String: Self.vendorID,
             kIOHIDDeviceUsagePageKey as String: 0x01,
             kIOHIDDeviceUsageKey as String: usage]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        // Event-driven detection: rescan the instant an 8BitDo device appears
        // or disappears, instead of waking every 2 s forever to poll. The
        // callback captures nothing (it reads its context arg), so it is a
        // valid C function pointer. A slow safety poll below still covers the
        // rare missed-event-during-mode-switch case the old comment worried
        // about, so behavior is preserved while idle wakes drop ~7x.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context = context else { return }
            let me = Unmanaged<EightBitDoDetector>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in me.rescan() }
            // GameController may list the controller a moment later; look
            // again before settling on a mode hint.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { me.rescan() }
            }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, cb, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, cb, ctx)

        // Never opened: matching callbacks, IOHIDManagerCopyDevices, and
        // property reads all work on an unopened manager, and opening one
        // would open every matched 8BitDo interface, keyboards included,
        // which is what triggers the Input Monitoring prompt.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// Detection is event-driven (match/removal callbacks in setupManager); this
    /// slow 15 s poll is only a safety net for events IOHIDManager can miss
    /// during 8BitDo mode switches. rescan() is idempotent and change-gated, so
    /// the poll costs nothing between actual connect/disconnect changes.
    private func startPolling() {
        rescanTimer?.invalidate()
        rescan()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        if let timer = rescanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func rescan() {
        guard let manager = manager else { return }
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            var none: [EightBitDoDevice] = []
            #if DEBUG
            if let fake = debugFake { none = [fake] }
            #endif
            if detectedDevices != none { detectedDevices = none }
            return
        }

        var seen = Set<UInt64>()
        var newDevices: [EightBitDoDevice] = []

        for device in deviceSet {
            guard let pidRef = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
                  let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else { continue }

            let pid = pidRef.int32Value
            let location = locRef.uint64Value
            if seen.contains(location) { continue }
            seen.insert(location)

            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "8BitDo Controller"
            let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "Unknown"
            let listed = RawHIDGamepadService.gameControllerLists(
                vendorID: Self.vendorID, productID: pid, productName: name)
            let mode = Self.mode(productID: pid, productName: name, listedByGameController: listed)

            newDevices.append(EightBitDoDevice(
                id: location,
                productID: pid,
                productName: name,
                transport: transport,
                mode: mode
            ))
        }

        // Order by location for stable display
        newDevices.sort { $0.id < $1.id }
        #if DEBUG
        if let fake = debugFake { newDevices.append(fake) }
        #endif

        // Only publish if something changed
        if newDevices != detectedDevices {
            detectedDevices = newDevices
        }
    }

    // MARK: - Mode Detection

    /// The mode to report for a device. A controller GameController lists
    /// works on macOS whatever its mode; one it does not list gets the
    /// mode hint, named from the product string when it says, else the
    /// generic "not seen by GameController" hint.
    static func mode(productID: Int32, productName: String, listedByGameController: Bool) -> EightBitDoMode {
        let named = detectMode(productID: productID, productName: productName)
        if listedByGameController {
            return named.supportedByMacOS ? named : .apple
        }
        return named.supportedByMacOS || named == .unknown ? .notSeenByGameController : named
    }

    /// The mode named in the product string, if any. The product ID is not
    /// used: 8BitDo reuses IDs across models and modes, and the old ID
    /// ranges called D-input and Steam mode identities Apple mode and
    /// plain HID dongles XInput.
    static func detectMode(productID: Int32, productName: String) -> EightBitDoMode {
        let lower = productName.lowercased()
        if lower.contains("mfi") || lower.contains("apple") { return .apple }
        if lower.contains("xinput") || lower.contains("xbox") { return .xinput }
        if lower.contains("dinput") { return .dinput }
        if lower.contains("switch") || lower.contains("ns ") { return .nintendoSwitch }
        if lower.contains("android") { return .android }
        return .unknown
    }
}
