import Foundation
import Combine

/// Inert successor to the old external-input monitoring service.
///
/// ## Why this is empty now
///
/// Earlier builds used a session-level `CGEventTap` plus an
/// `IOHIDManager` matched on keyboard / mouse usages to let the user
/// bind their Mac's built-in or external keyboard / mouse as **input
/// sources**. Reading the system keystroke stream that way requires the
/// macOS Input Monitoring / Accessibility permission, and App Store
/// review (guideline 2.4.5) rejects apps that consume those permissions
/// for a non-accessibility purpose. The feature has been removed.
///
/// The type is kept as an inert shell so the rest of the codebase keeps
/// compiling: the binding model still has `.extKey` / `.extMouse` cases
/// for decoding presets saved by older builds, and a few views observe
/// this object. Everything here is now empty / false:
///   - `devices` is always empty (no enumeration).
///   - `events` never fires (no tap, no HID callbacks).
///   - `rawActiveInputs` stays empty (nothing to highlight).
///
/// Game controllers are unaffected - they come through the
/// GameController framework (`GameControllerService`) and raw HID
/// *gamepads* through `RawHIDGamepadService`, neither of which needs
/// Input Monitoring. Cursor-position based bindings (`.cursorRegion`)
/// now read `NSEvent.mouseLocation` directly in `CursorRegionService`,
/// which needs no permission at all.
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

        var deviceID: String {
            switch self {
            case .keyDown(let id, _), .keyUp(let id, _),
                 .mouseButtonDown(let id, _), .mouseButtonUp(let id, _),
                 .mouseMove(let id, _, _), .scroll(let id, _, _):
                return id
            }
        }
    }

    struct LoggedEvent: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let label: String
    }

    // MARK: - Published state (all permanently empty)

    @Published private(set) var devices: [Device] = []
    @Published private(set) var recentEvents: [String: [LoggedEvent]] = [:]
    @Published private(set) var receivedAnyKeyboardEvent = false
    @Published private(set) var rawActiveInputs: Set<String> = []

    /// Never fires. Subscribers attach harmlessly and receive nothing.
    let events = PassthroughSubject<Event, Never>()

    /// Always false now - we no longer install a system event tap.
    @Published private(set) var cgEventTapInstalled = false
    @Published private(set) var cgEventTapReceivedAnyEvent = false

    /// Synthetic device IDs kept only so binding strings saved by older
    /// builds ("ekb 4 builtin.keyboard") still parse without crashing.
    static let builtInKeyboardID = "builtin.keyboard"
    static let builtInMouseID = "builtin.mouse"

    private static let excludeBuiltInKey = "JoystickConfig.externalInput.excludeBuiltIn"

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
    }

    // MARK: - Public lookup (return empty / nil)

    func deviceName(for id: String) -> String? { nil }

    func recentEventsFor(_ id: String) -> [LoggedEvent] { [] }

    /// No-op: there is no tap or HID manager to tear down anymore.
    /// Kept so the app-termination path in `AppState` still compiles.
    func teardownForTermination() {}
}
