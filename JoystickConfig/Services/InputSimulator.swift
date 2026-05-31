#if os(macOS)
import Foundation
import CoreGraphics
import AppKit

/// Simulates keyboard and mouse input on macOS using CGEvent.
///
/// IMPORTANT: Accessibility permission is tracked per code signature.
/// During development with ad-hoc signing (CODE_SIGN_IDENTITY = "-"),
/// you must re-grant permission in System Settings after each rebuild.
/// Remove old entries and re-add the newly built app.
final class InputSimulator: @unchecked Sendable {
    nonisolated(unsafe) static let shared = InputSimulator()

    private var pressedKeys: Set<Int> = []
    private var pressedMouseButtons: Set<Int> = []

    /// Cached event source for synthetic events. Created once on first
    /// access. Previously this was a computed property, which meant
    /// every key press / mouse motion / scroll wheel call paid the
    /// CGEventSource initialization cost. On a turbo-firing or
    /// joystick-as-mouse preset that was many hundreds of allocations
    /// per second.
    private lazy var eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)

    /// Magic marker we stamp onto every `CGEvent` we post via this class.
    /// `ExternalInputDeviceService`'s `CGEventTap` reads back this field
    /// and ignores any event carrying this marker - that's how we
    /// guarantee a binding's keyboard OUTPUT can't loop back as keyboard
    /// INPUT and trigger itself. "INPUTC01" in ASCII.
    nonisolated(unsafe) static let ownEventMarker: Int64 = 0x49_4E_50_55_54_43_30_31

    /// Post a CGEvent we created, after stamping our marker so the
    /// CGEventTap consumer can recognize and skip it. All post call sites
    /// in this file go through here.
    ///
    /// IMPORTANT: posts to **`.cghidEventTap`**, not `.cgSessionEventTap`.
    /// `.cghidEventTap` is the lowest-level tap - events appear as if
    /// from real HID hardware, BEFORE the WindowServer's "is this app
    /// trusted to post events" filter runs. That filter is what gates
    /// `.cgSessionEventTap` posts on the Accessibility permission and
    /// silently drops events from apps that haven't been granted it.
    /// Posting at the HID layer is how Enjoyable, BetterMouse, Karabiner
    /// and similar input remappers ship without requiring users to add
    /// the app to System Settings → Privacy & Security → Accessibility.
    fileprivate func taggedPost(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.ownEventMarker)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard Simulation

    func keyDown(_ hidCode: Int) {
        guard !pressedKeys.contains(hidCode) else { return }
        pressedKeys.insert(hidCode)

        if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
            let flags = modifierFlags(for: hidCode)
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: true) {
                if let flags = flags {
                    event.flags = flags
                }
                taggedPost(event)
            }
        } else {
            postSpecialKey(hidCode, keyDown: true)
        }
    }

    func keyUp(_ hidCode: Int) {
        guard pressedKeys.contains(hidCode) else { return }
        pressedKeys.remove(hidCode)

        if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: false) {
                taggedPost(event)
            }
        } else {
            postSpecialKey(hidCode, keyDown: false)
        }
    }

    private func modifierFlags(for hidCode: Int) -> CGEventFlags? {
        switch hidCode {
        case 224, 228: return .maskControl
        case 225, 229: return .maskShift
        case 226, 230: return .maskAlternate
        case 227, 231: return .maskCommand
        default: return nil
        }
    }

    /// HID code → NSEvent.subtype:systemDefined NX key code. Static so
    /// it's allocated once at type init, not per call. Was previously
    /// a local `let` inside `postSpecialKey`, allocating a fresh dict
    /// on every media-key press.
    private static let specialKeyMap: [Int: Int] = [
        71: 0x91,   // Brightness Down
        72: 0x90,   // Brightness Up
        307: 0x14,  // Rewind
        308: 0x10,  // Play/Pause
        309: 0x13,  // Fast Forward
        310: 0x07,  // Mute
        311: 0x00,  // Volume Up
        312: 0x01,  // Volume Down
    ]

    private func postSpecialKey(_ hidCode: Int, keyDown: Bool) {
        guard let nxKeyType = Self.specialKeyMap[hidCode] else { return }

        let flags: Int = keyDown ? 0xa00 : 0xb00
        let data1 = (nxKeyType << 16) | flags
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        if let cg = event?.cgEvent { taggedPost(cg) }
    }

    // MARK: - Mouse Button Simulation

    func mouseButtonDown(_ button: Int) {
        guard !pressedMouseButtons.contains(button) else { return }
        // `NSScreen.main` can be nil during sleep/wake transitions and
        // fast-user-switching, and CGMouseButton(rawValue:) returns nil
        // for buttons outside 0...31. Either case used to force-unwrap
        // and crash the entire mapping engine mid-binding; now both
        // fall back gracefully.
        guard let screenHeight = NSScreen.main?.frame.height,
              let cgButton = cgMouseButton(for: button) else { return }
        pressedMouseButtons.insert(button)

        let location = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

        let eventType: CGEventType
        switch button {
        case 0: eventType = .leftMouseDown
        case 1: eventType = .rightMouseDown
        default: eventType = .otherMouseDown
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: eventType,
                               mouseCursorPosition: cgPoint, mouseButton: cgButton) {
            taggedPost(event)
        }
    }

    func mouseButtonUp(_ button: Int) {
        guard pressedMouseButtons.contains(button) else { return }
        guard let screenHeight = NSScreen.main?.frame.height,
              let cgButton = cgMouseButton(for: button) else { return }
        pressedMouseButtons.remove(button)

        let location = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

        let eventType: CGEventType
        switch button {
        case 0: eventType = .leftMouseUp
        case 1: eventType = .rightMouseUp
        default: eventType = .otherMouseUp
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: eventType,
                               mouseCursorPosition: cgPoint, mouseButton: cgButton) {
            taggedPost(event)
        }
    }

    /// Map a JoystickConfig logical mouse-button index to CGMouseButton.
    /// Returns nil for indices that don't have a CGMouseButton equivalent
    /// instead of force-unwrapping; the caller drops the event.
    private func cgMouseButton(for index: Int) -> CGMouseButton? {
        switch index {
        case 0: return .left
        case 1: return .right
        default: return CGMouseButton(rawValue: UInt32(index))
        }
    }

    // MARK: - Mouse Motion Simulation

    func moveMouse(deltaX: Int, deltaY: Int) {
        let location = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        let currentPoint = CGPoint(x: location.x, y: screenHeight - location.y)
        let newPoint = CGPoint(x: currentPoint.x + CGFloat(deltaX), y: currentPoint.y + CGFloat(deltaY))

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                               mouseCursorPosition: newPoint, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
            taggedPost(event)
        }
    }

    // MARK: - Mouse Wheel Simulation

    func scrollWheel(deltaX: Int32, deltaY: Int32) {
        if let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                               wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) {
            taggedPost(event)
        }
    }

    func scrollWheelStep(axis: MouseAxis, direction: MouseDirection) {
        let delta: Int32 = direction == .positive ? 5 : -5
        switch axis {
        case .vertical:
            scrollWheel(deltaX: 0, deltaY: delta)
        case .horizontal:
            scrollWheel(deltaX: delta, deltaY: 0)
        }
    }

    // MARK: - Release All

    func releaseAll() {
        for key in pressedKeys {
            if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[key] {
                if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: false) {
                    taggedPost(event)
                }
            }
        }
        pressedKeys.removeAll()

        for button in pressedMouseButtons {
            mouseButtonUp(button)
        }
        pressedMouseButtons.removeAll()
    }

    // MARK: - Diagnostic Test

    /// Test that event creation + posting works. Returns a description
    /// of what happened.
    ///
    /// Note: output is synthesized at the HID layer via `.cghidEventTap`
    /// (see `taggedPost`), which does NOT require the Accessibility
    /// permission - so there is intentionally no `AXIsProcessTrusted`
    /// check here. The app never requests Accessibility.
    static func runDiagnostic() -> String {
        var results: [String] = []

        // 1. Check if we can create an event source
        let source = CGEventSource(stateID: .hidSystemState)
        results.append("Event Source: \(source != nil ? "OK" : "FAILED")")

        // 2. Check if we can create a keyboard event
        let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        results.append("Key Event Create: \(keyEvent != nil ? "OK" : "FAILED")")

        // 3. Check if we can create a mouse move event
        let mouseEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: .zero, mouseButton: .left)
        results.append("Mouse Event Create: \(mouseEvent != nil ? "OK" : "FAILED")")

        // 4. Try posting a harmless mouse move with zero delta
        if let event = mouseEvent {
            event.setIntegerValueField(.mouseEventDeltaX, value: 0)
            event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            // taggedPost is an instance method; use the singleton.
            InputSimulator.shared.taggedPost(event)
            results.append("Event Post: OK (no error)")
        } else {
            results.append("Event Post: SKIPPED (no event)")
        }

        // 5. App path
        results.append("App Path: \(Bundle.main.bundlePath)")

        return results.joined(separator: "\n")
    }
}

#else

// iOS stub - input simulation not available
final class InputSimulator: @unchecked Sendable {
    nonisolated(unsafe) static let shared = InputSimulator()

    func keyDown(_ hidCode: Int) {}
    func keyUp(_ hidCode: Int) {}
    func mouseButtonDown(_ button: Int) {}
    func mouseButtonUp(_ button: Int) {}
    func moveMouse(deltaX: Int, deltaY: Int) {}
    func scrollWheel(deltaX: Int32, deltaY: Int32) {}
    func scrollWheelStep(axis: MouseAxis, direction: MouseDirection) {}
    func releaseAll() {}

    static func runDiagnostic() -> String { "iOS: Not supported" }
}

#endif
