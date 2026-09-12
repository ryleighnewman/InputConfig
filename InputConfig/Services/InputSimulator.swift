#if os(macOS)
import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio
import AudioToolbox

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

        // Globe / fn is a pure modifier here. Posting a real fn key event would
        // trigger whatever single-press action the user has assigned to it, so
        // it only ever decorates the keys pressed alongside it.
        if hidCode == KeyCodeMap.globeFnCode { return }

        if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: true) {
                // Apply EVERY currently-held modifier, not just the case where
                // this key is itself a modifier. Without this, a chord like
                // Cmd+C (Cmd held, then C pressed) fired C as a bare key because
                // the C event carried no modifier flags, so combo outputs like
                // Copy, the screenshot shortcuts, and Cmd+Shift+Z did nothing.
                var flags = currentModifierFlags()
                // PATCH: a modifier pressed on its own must arrive as a
                // flagsChanged event (exactly what a physical keyboard sends),
                // otherwise apps that watch for a lone Option / Cmd tap
                // (voice-input toggles, IME switchers) never see it. Flags are
                // always written explicitly (never inherited from the event
                // source) and carry the left/right device bit like real keys.
                if modifierFlags(for: hidCode) != nil {
                    event.type = .flagsChanged
                    flags.insert(deviceModifierBit(for: hidCode))
                    flags.insert(.maskNonCoalesced)
                    event.flags = flags
                } else if !flags.isEmpty { event.flags = flags }
                taggedPost(event)
            }
        } else {
            postSpecialKey(hidCode, keyDown: true)
        }
    }

    func keyUp(_ hidCode: Int) {
        guard pressedKeys.contains(hidCode) else { return }
        pressedKeys.remove(hidCode)

        // Globe / fn is a pure modifier here. Posting a real fn key event would
        // trigger whatever single-press action the user has assigned to it, so
        // it only ever decorates the keys pressed alongside it.
        if hidCode == KeyCodeMap.globeFnCode { return }

        if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: false) {
                // Carry the still-held modifiers so releasing the letter of a
                // chord (e.g. the C of Cmd+C) does not read as a bare key-up.
                var flags = currentModifierFlags()
                // PATCH: see keyDown. On release the modifier is already gone
                // from pressedKeys; write the (possibly empty) flags explicitly
                // so the release is not inherited as "still held".
                if modifierFlags(for: hidCode) != nil {
                    event.type = .flagsChanged
                    flags.insert(.maskNonCoalesced)
                    event.flags = flags
                } else if !flags.isEmpty { event.flags = flags }
                taggedPost(event)
            }
        } else {
            postSpecialKey(hidCode, keyDown: false)
        }
    }

    /// Type a literal string by posting keyboard events whose characters are
    /// set with keyboardSetUnicodeString, in 20-UTF-16-unit chunks (the API's
    /// per-event limit). Goes through the same taggedPost path as every other
    /// output, so the string cannot loop back as input and no new permission
    /// surface is involved. Capitals, symbols, and non-Latin text all work
    /// because the characters bypass keycode translation entirely.
    func typeString(_ text: String) {
        guard !text.isEmpty else { return }
        // Chunk on grapheme (Character) boundaries so a surrogate pair (emoji,
        // astral chars) or a combining sequence is never split across the
        // 20-UTF-16-unit API limit, which would corrupt the character.
        var chunk: [UInt16] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                taggedPost(down)
            }
            if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                taggedPost(up)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for character in text {
            let u = Array(String(character).utf16)
            if !chunk.isEmpty && chunk.count + u.count > 20 { flush() }
            if u.count > 20 {
                // A single grapheme wider than the limit is pathological; post
                // it on its own rather than dropping or splitting it.
                flush()
                chunk = u
                flush()
                continue
            }
            chunk.append(contentsOf: u)
        }
        flush()
    }

    /// Device-specific modifier bit (NX_DEVICEL*/R* masks) so a synthesized
    /// left or right modifier looks like the physical key it stands for.
    private func deviceModifierBit(for hidCode: Int) -> CGEventFlags {
        switch hidCode {
        case 224: return CGEventFlags(rawValue: 0x0001)   // left control
        case 228: return CGEventFlags(rawValue: 0x2000)   // right control
        case 225: return CGEventFlags(rawValue: 0x0002)   // left shift
        case 229: return CGEventFlags(rawValue: 0x0004)   // right shift
        case 226: return CGEventFlags(rawValue: 0x0020)   // left option
        case 230: return CGEventFlags(rawValue: 0x0040)   // right option
        case 227: return CGEventFlags(rawValue: 0x0008)   // left command
        case 231: return CGEventFlags(rawValue: 0x0010)   // right command
        default: return []
        }
    }

    private func modifierFlags(for hidCode: Int) -> CGEventFlags? {
        switch hidCode {
        case 224, 228: return .maskControl
        case 225, 229: return .maskShift
        case 226, 230: return .maskAlternate
        case 227, 231: return .maskCommand
        case KeyCodeMap.globeFnCode: return .maskSecondaryFn
        default: return nil
        }
    }

    /// Union of the modifier flags for every modifier key currently held in
    /// `pressedKeys`. Applied to every synthesized key event so chords such as
    /// Cmd+C, Cmd+Shift+3, and Option+[ register with their modifiers instead
    /// of firing as bare keys.
    private func currentModifierFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        for code in pressedKeys {
            if let f = modifierFlags(for: code) { flags.insert(f) }
        }
        return flags
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
        guard let screenHeight = NSScreen.screens.first?.frame.height,
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
        guard let cgButton = cgMouseButton(for: button) else { return }
        // Always release. NSScreen.main can be nil during sleep/wake and fast
        // user switching; if we bailed on that the button would stay physically
        // down. Fall back to a zero-height screen so the up event still posts
        // and our pressed-state stays consistent.
        pressedMouseButtons.remove(button)

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
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

    /// Map a InputConfig logical mouse-button index to CGMouseButton.
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

    /// Cursor position we last posted, so continuous motion does not ask the
    /// window server where the cursor is on every poll frame (that call plus
    /// the screen lookup was the cost behind "Variable Sensitivity spikes
    /// the CPU"). Re-read from the system after an idle gap, when the user
    /// may have moved the real mouse, and every 8th frame so the tracked
    /// point cannot drift past a screen edge for long.
    private var trackedCursor: CGPoint?
    private var trackedAt: TimeInterval = 0
    private var trackedFrames = 0
    private var cachedScreenHeight: CGFloat = 0

    func moveMouse(deltaX: Int, deltaY: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        trackedFrames &+= 1
        if trackedCursor == nil || now - trackedAt > 0.1 || trackedFrames % 8 == 0 {
            let location = NSEvent.mouseLocation
            if let h = NSScreen.screens.first?.frame.height { cachedScreenHeight = h }
            if cachedScreenHeight == 0 { cachedScreenHeight = 1080 }
            trackedCursor = CGPoint(x: location.x, y: cachedScreenHeight - location.y)
        }
        trackedAt = now
        var point = trackedCursor ?? .zero
        point.x += CGFloat(deltaX)
        point.y += CGFloat(deltaY)
        trackedCursor = point

        // A move while a mapped button is held must be a drag event, or
        // window moves, text selection, sliders and drag-and-drop never
        // happen: the system does not promote a plain move into a drag.
        let type: CGEventType
        let button: CGMouseButton
        if pressedMouseButtons.contains(0) {
            type = .leftMouseDragged; button = .left
        } else if pressedMouseButtons.contains(1) {
            type = .rightMouseDragged; button = .right
        } else if let other = pressedMouseButtons.first, let cg = cgMouseButton(for: other) {
            type = .otherMouseDragged; button = cg
        } else {
            type = .mouseMoved; button = .left
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                               mouseCursorPosition: point, mouseButton: button) {
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
            } else {
                // Media / special keys live outside the virtual-key map; route
                // them through the systemDefined path so they release too and
                // don't stick down after stop() or pause.
                postSpecialKey(key, keyDown: false)
            }
        }
        pressedKeys.removeAll()

        for button in pressedMouseButtons {
            mouseButtonUp(button)
        }
        pressedMouseButtons.removeAll()
    }

    #if DEBUG
    /// How many keys the simulator currently holds down. Used by the smoke
    /// test to prove the emergency stop actually let go of them.
    var debugHeldKeyCount: Int { pressedKeys.count + pressedMouseButtons.count }
    #endif

    // MARK: - Diagnostic Test

    /// Test that event creation + posting works. Returns a description
    /// of what happened.
    ///
    /// Note: output is synthesized at the HID layer via `.cghidEventTap`
    /// (see `taggedPost`). Delivery to other apps requires the Accessibility
    /// permission, which `AccessibilityPermissionService.requestAccess()`
    /// asks for; this diagnostic only verifies that event creation and
    /// posting do not fail, so it intentionally runs without an
    /// `AXIsProcessTrusted` check.
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

/// Tracks and helps the user grant the macOS Accessibility permission,
/// which InputConfig needs to deliver the keyboard and mouse actions a
/// user maps to their controller. This is the app's one approved use of
/// Accessibility (App Store guideline 2.4.5): it is used solely to perform
/// the user's own mappings, never to read or monitor input.
///
/// macOS posts no notification when this permission changes, so we re-check
/// on app activation and via a short poll after we prompt.
@MainActor
final class AccessibilityPermissionService: ObservableObject {
    static let shared = AccessibilityPermissionService()

    /// True when the app is trusted for Accessibility (allowed to deliver
    /// synthetic keyboard/mouse events to other apps).
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var pollTimer: Timer?
    private var pollTicks = 0

    private init() {
        // The user usually grants the permission in System Settings and then
        // switches back to us, so re-check whenever we become the active app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-read the current trust state, publishing only on change.
    func refresh() {
        let now = AXIsProcessTrusted()
        if now != isTrusted { isTrusted = now }
    }

    /// Show the standard macOS "allow Accessibility" prompt, open the
    /// Accessibility pane, and poll so our UI flips to granted the moment
    /// the user enables InputConfig.
    func requestAccess() {
        // Use the literal key string rather than the global
        // `kAXTrustedCheckOptionPrompt`, which Swift 6 strict concurrency
        // rejects as a non-Sendable mutable global. The value is stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSystemSettings()
    }

    /// Open System Settings directly to Privacy & Security -> Accessibility,
    /// and start polling for the user to toggle us on.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPolling()
    }

    /// Poll the trust state for up to ~2 minutes (TCC changes aren't
    /// observable), stopping early once granted.
    func startPolling() {
        pollTimer?.invalidate()
        pollTicks = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refresh()
                self.pollTicks += 1
                if self.isTrusted || self.pollTicks >= 120 {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Registers one system-wide keyboard shortcut (Control + Option + Command +
/// P) that toggles the most recently used preset on or off, even while another
/// app is in front. Uses Carbon's `RegisterEventHotKey`, which is allowed
/// inside the App Sandbox and needs no extra entitlement or permission. When
/// the chord is pressed it posts `toggleNotification`; ContentView listens and
/// performs the toggle on the main actor. Off by default; the user opts in
/// from Settings.
/// One Carbon event handler for every global shortcut in the app.
///
/// Carbon delivers hot-key presses to every installed handler, so a
/// per-service handler that ignores the event's ID fires on shortcuts it
/// does not own. This owns the single handler, reads the ID off the
/// event, and calls only the action registered for it.
final class HotKeyCenter: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HotKeyCenter()

    private let lock = NSLock()
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1

    private init() {}

    /// Registers a system-wide chord. Returns a token for `unregister`, or
    /// nil when the chord is unavailable (usually another app owns it).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32,
                  action: @escaping () -> Void) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        guard installHandlerLocked() else { return nil }

        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A4B4350), id: id)  // 'JKCP'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("HotKeyCenter: RegisterEventHotKey failed (status \(status)); the chord may be taken by another app")
            return nil
        }
        refs[id] = ref
        actions[id] = action
        return id
    }

    func unregister(_ token: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if let ref = refs.removeValue(forKey: token) { UnregisterEventHotKey(ref) }
        actions.removeValue(forKey: token)
    }

    /// Called from the C callback with the ID read off the event.
    fileprivate func fire(_ id: UInt32) {
        lock.lock()
        let action = actions[id]
        lock.unlock()
        action?()
    }

    private func installHandlerLocked() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         hotKeyDispatchCallback, 1, &spec, nil, &handlerRef)
        guard status == noErr else {
            NSLog("HotKeyCenter: InstallEventHandler failed (status \(status)); global shortcuts are unavailable")
            handlerRef = nil
            return false
        }
        return true
    }
}

/// Capture-free C callback: reads the hot-key ID off the event and hands it
/// to the center on the main queue.
private let hotKeyDispatchCallback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
    guard let eventRef else { return noErr }
    var hkID = EventHotKeyID()
    let status = GetEventParameter(eventRef,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard status == noErr else { return noErr }
    let id = hkID.id
    DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
    return noErr
}

/// A recorded chord: a virtual key code plus Carbon modifier mask.
struct HotKeySpec: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Chord as the user reads it, e.g. "Control Option Command ." using the
    /// standard macOS glyphs.
    var displayString: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "\u{2303}" }
        if modifiers & UInt32(optionKey)  != 0 { out += "\u{2325}" }
        if modifiers & UInt32(shiftKey)   != 0 { out += "\u{21E7}" }
        if modifiers & UInt32(cmdKey)     != 0 { out += "\u{2318}" }
        return out + HotKeySpec.keyName(for: keyCode)
    }

    /// True when this is a bare key you would normally type, so registering
    /// it system-wide would swallow it everywhere. Function keys, arrows and
    /// the navigation cluster are fine on their own.
    var stealsATypingKey: Bool {
        guard modifiers == 0 else { return false }
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
             kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
             kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            return false
        default:
            return true
        }
    }

    static func keyName(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Comma:  return ","
        case kVK_ANSI_Slash:  return "/"
        case kVK_Escape:      return "esc"
        case kVK_Space:       return "space"
        case kVK_Delete:      return "delete"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            if let key = KeyCodeMap.allKeys.first(where: {
                ExternalInputDeviceService.hidUsage(forVirtualKeyCode: Int(code)) == $0.code
            }) {
                return key.name
            }
            return "Key \(code)"
        }
    }
}

/// The app-wide kill switch.
///
/// One rule: this only ever STOPS. It never activates a preset, so it is
/// safe to hit when you cannot see the screen or do not know what state the
/// app is in. It is reachable three ways, deliberately redundant, because
/// the whole point is that one of them is available when the others are not:
/// a system-wide chord, holding a button on the controller itself, and the
/// menu bar. The controller path matters most: if a preset has taken over
/// the keyboard and mouse, the controller may be the only input you have.
final class EmergencyStopService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = EmergencyStopService()

    /// Posted after a stop so the UI can deactivate the preset and confirm.
    static let stoppedNotification = Notification.Name("InputConfig.EmergencyStopped")

    static let enabledKey       = "InputConfig.panicHotkeyEnabled"
    static let keyCodeKey       = "InputConfig.panicKeyCode"
    static let modifiersKey     = "InputConfig.panicModifiers"
    static let controllerKey    = "InputConfig.panicControllerEnabled"
    static let controllerBtnKey = "InputConfig.panicControllerButton"
    static let holdSecondsKey   = "InputConfig.panicHoldSeconds"

    /// Control + Option + Command + period. Period is the Mac's cancel key,
    /// and the three modifiers keep it clear of anything an app or game binds.
    static let defaultSpec = HotKeySpec(keyCode: UInt32(kVK_ANSI_Period),
                                        modifiers: UInt32(controlKey | optionKey | cmdKey))
    /// Home / PS / Guide. Almost never mapped, and present on every
    /// mainstream controller.
    static let defaultControllerButton = 10
    static let defaultHoldSeconds = 2.0

    private var token: UInt32?
    private(set) var isRegistered = false

    private init() {}

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: true,
            keyCodeKey: Int(defaultSpec.keyCode),
            modifiersKey: Int(defaultSpec.modifiers),
            controllerKey: true,
            controllerBtnKey: defaultControllerButton,
            holdSecondsKey: defaultHoldSeconds,
        ])
    }

    var spec: HotKeySpec {
        let d = UserDefaults.standard
        let code = d.object(forKey: Self.keyCodeKey) as? Int
        let mods = d.object(forKey: Self.modifiersKey) as? Int
        return HotKeySpec(keyCode: UInt32(code ?? Int(Self.defaultSpec.keyCode)),
                          modifiers: UInt32(mods ?? Int(Self.defaultSpec.modifiers)))
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // The engine asks for these on every poll frame, so they are cached in
    // memory rather than read from UserDefaults each time. A preference read
    // walks the CFPreferences search list, which was costing a third of the
    // poll loop at 120 Hz. Refreshed whenever defaults change.
    private var cachedHoldEnabled = true
    private var cachedButton = EmergencyStopService.defaultControllerButton
    private var cachedHoldSeconds = EmergencyStopService.defaultHoldSeconds
    private var defaultsObserver: NSObjectProtocol?

    var controllerHoldEnabled: Bool { cachedHoldEnabled }
    var controllerButton: Int { cachedButton }
    var holdSeconds: Double { cachedHoldSeconds }

    /// Pull the controller-hold settings into memory. Called at registration
    /// and whenever any default changes.
    func refreshCachedSettings() {
        let d = UserDefaults.standard
        cachedHoldEnabled = d.bool(forKey: Self.controllerKey)
        cachedButton = (d.object(forKey: Self.controllerBtnKey) as? Int)
            ?? Self.defaultControllerButton
        let secs = d.double(forKey: Self.holdSecondsKey)
        cachedHoldSeconds = secs > 0 ? secs : Self.defaultHoldSeconds
    }

    private func observeDefaults() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshCachedSettings()
        }
    }

    /// (Re-)register the chord to match the current settings. Safe to call
    /// repeatedly; it tears down the previous registration first.
    @discardableResult
    func refreshRegistration() -> Bool {
        refreshCachedSettings()
        observeDefaults()
        if let t = token { HotKeyCenter.shared.unregister(t); token = nil }
        isRegistered = false
        guard isEnabled else { return true }
        let s = spec
        guard let t = HotKeyCenter.shared.register(keyCode: s.keyCode, modifiers: s.modifiers,
                                                   action: { EmergencyStopService.shared.stop(reason: .hotkey) })
        else { return false }
        token = t
        isRegistered = true
        return true
    }

    func setSpec(_ newSpec: HotKeySpec) {
        let d = UserDefaults.standard
        d.set(Int(newSpec.keyCode), forKey: Self.keyCodeKey)
        d.set(Int(newSpec.modifiers), forKey: Self.modifiersKey)
        refreshRegistration()
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        refreshRegistration()
    }

    enum Reason: String {
        case hotkey = "keyboard shortcut"
        case controllerHold = "controller button held"
        case binding = "a binding"
        case menu = "the menu"
    }

    /// Stop everything, in the order that matters: halt the engine first so
    /// nothing is re-pressed on the next frame, then let go of every key,
    /// button, and note we are holding, then put the cursor back.
    func stop(reason: Reason) {
        let work = {
            // 1. Engine and preset. Observers run synchronously on this
            //    thread, so the poll loop is stopped before we release.
            NotificationCenter.default.post(name: Self.stoppedNotification,
                                            object: nil,
                                            userInfo: ["reason": reason.rawValue])
            // 2. Let go of everything we are holding down.
            InputSimulator.shared.releaseAll()
            MIDIService.shared.releaseAllNotes()
            // 3. Give the pointer back. CursorGuardService is main-actor
            //    isolated and this block only ever runs on the main thread.
            MainActor.assumeIsolated {
                CursorGuardService.shared.clearPresetOverride()
                CursorGuardService.shared.forceShowCursor()
            }
            NSLog("InputConfig: emergency stop (\(reason.rawValue))")
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// Per-preset activation shortcuts. Each preset that defines one gets a
/// system-wide chord that switches to it; pressing it again while that
/// preset is the active one stops it.
final class PresetHotKeyService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = PresetHotKeyService()

    /// Posted with the preset id in `object` when its chord is pressed.
    static let activateNotification = Notification.Name("InputConfig.ActivatePresetHotKey")

    private var tokens: [UUID: UInt32] = [:]
    /// Chords that could not be claimed, so Settings can say so.
    private(set) var failed: Set<UUID> = []

    private init() {}

    /// Re-register every preset chord. Called whenever the library changes.
    func sync(with presets: [Preset]) {
        for (_, token) in tokens { HotKeyCenter.shared.unregister(token) }
        tokens.removeAll()
        failed.removeAll()
        for preset in presets {
            guard let spec = preset.activateHotKey else { continue }
            let id = preset.id
            if let token = HotKeyCenter.shared.register(
                keyCode: spec.keyCode, modifiers: spec.modifiers,
                action: {
                    NotificationCenter.default.post(
                        name: PresetHotKeyService.activateNotification, object: id)
                }) {
                tokens[id] = token
            } else {
                failed.insert(id)
            }
        }
    }

    /// True when two presets ask for the same chord, or one collides with
    /// the emergency stop, so the editor can warn instead of failing silently.
    static func conflicts(for spec: HotKeySpec, excluding presetID: UUID?,
                          in presets: [Preset]) -> Bool {
        if EmergencyStopService.shared.isEnabled,
           EmergencyStopService.shared.spec == spec { return true }
        return presets.contains { $0.id != presetID && $0.activateHotKey == spec }
    }
}

/// The system-wide "toggle the most recent preset" chord. Unchanged in
/// behavior; it now goes through HotKeyCenter so it only fires for its own
/// chord rather than for every hot key the app registers.
final class GlobalHotKeyService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = GlobalHotKeyService()
    static let toggleNotification = Notification.Name("InputConfig.ToggleRecentPreset")
    /// UserDefaults key shared by Settings (the toggle) and AppState (boot).
    static let enabledDefaultsKey = "InputConfig.globalHotkeyEnabled"

    private var token: UInt32?
    private(set) var isEnabled = false

    /// Human-readable chord, shown in Settings.
    let shortcutDescription = "Control + Option + Command + P"

    private init() {}

    /// Returns false when registration fails (typically because another app
    /// owns the chord) so callers can keep their on/off UI truthful.
    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }
        guard let t = HotKeyCenter.shared.register(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            action: {
                NotificationCenter.default.post(
                    name: GlobalHotKeyService.toggleNotification, object: nil)
            }) else { return false }
        token = t
        isEnabled = true
        return true
    }

    func disable() {
        if let t = token { HotKeyCenter.shared.unregister(t); token = nil }
        isEnabled = false
    }

    /// Apply a desired on/off state and persist it.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledDefaultsKey)
        if on { enable() } else { disable() }
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

@MainActor
final class AccessibilityPermissionService: ObservableObject {
    static let shared = AccessibilityPermissionService()
    @Published private(set) var isTrusted: Bool = true
    func refresh() {}
    func requestAccess() {}
    func openSystemSettings() {}
    func startPolling() {}
}

#endif

// MARK: - System Volume

/// Sets the Mac's output volume to an absolute level, so a continuous
/// input (a MIDI knob, the pitch wheel, aftertouch, a controller trigger)
/// can act as a hardware volume fader: position equals level, 1-to-1.
/// This is different from the volume KEYS, which only nudge in steps.
///
/// Talks to CoreAudio's default output device directly. The device is
/// re-resolved when the default changes (AirPods connect, display audio,
/// etc.), and writes are suppressed below a small epsilon so a resting
/// knob costs nothing.
final class SystemVolumeService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = SystemVolumeService()

    private let lock = NSLock()
    private var cachedDevice: AudioObjectID = kAudioObjectUnknown
    private var lastSet: Float = -1

    private init() {
        // Refresh the cached device whenever the system default changes.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self else { return }
            self.lock.lock()
            self.cachedDevice = kAudioObjectUnknown
            self.lastSet = -1
            self.lock.unlock()
        }
    }

    private func defaultOutputDevice() -> AudioObjectID {
        if cachedDevice != kAudioObjectUnknown { return cachedDevice }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        if status == noErr { cachedDevice = device }
        return device
    }

    /// Set the output volume to `level` (0...1). Cheap to call every poll
    /// frame: identical or near-identical levels are dropped before any
    /// CoreAudio traffic happens.
    func setVolume(_ level: Float) {
        let clamped = max(0, min(1, level))
        lock.lock()
        if abs(clamped - lastSet) < 0.004 { lock.unlock(); return }
        lastSet = clamped
        let device = defaultOutputDevice()
        lock.unlock()
        guard device != kAudioObjectUnknown else { return }

        var value = clamped
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<Float>.size), &value)
    }
}


// MARK: - System actions

/// Executes .systemAction outputs: volume nudges and mute (CoreAudio),
/// media and brightness keys (system-defined aux-key events), Mac
/// shortcuts (Mission Control, Launchpad, Spotlight, lock screen,
/// screenshot), and automation (Siri Shortcuts, opening apps and URLs).
/// Everything here is App Sandbox safe.
final class SystemActionService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = SystemActionService()
    private init() {}

    /// How far one Volume Up / Down press moves, matching the keyboard's
    /// sixteen steps from silent to full.
    private let volumeStep: Float = 1.0 / 16.0

    func perform(_ kind: SystemActionKind, parameter: String?) {
        switch kind {
        case .volumeUp: nudgeVolume(by: volumeStep)
        case .volumeDown: nudgeVolume(by: -volumeStep)
        case .muteToggle: toggleMute()
        case .playPause: postAuxKey(16)      // NX_KEYTYPE_PLAY
        case .nextTrack: postAuxKey(19)      // NX_KEYTYPE_FAST
        case .previousTrack: postAuxKey(20)  // NX_KEYTYPE_REWIND
        case .brightnessUp: postAuxKey(2)    // NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown: postAuxKey(3)  // NX_KEYTYPE_BRIGHTNESS_DOWN
        case .keyboardBrightnessUp: postAuxKey(21)    // NX_KEYTYPE_ILLUMINATION_UP
        case .keyboardBrightnessDown: postAuxKey(22)  // NX_KEYTYPE_ILLUMINATION_DOWN
        case .startDictation:
            startDictation()
        case .speakSelection:
            postCombo(keyCode: 53, flags: .maskAlternate)                 // Option+Esc
        case .zoomToggle:
            postCombo(keyCode: 28, flags: [.maskAlternate, .maskCommand]) // Option+Cmd+8
        case .zoomIn:
            postCombo(keyCode: 24, flags: [.maskAlternate, .maskCommand]) // Option+Cmd+=
        case .zoomOut:
            postCombo(keyCode: 27, flags: [.maskAlternate, .maskCommand]) // Option+Cmd+-
        case .missionControl:
            openSystemApp("Mission Control")
        case .launchpad:
            openSystemApp("Launchpad")
        case .spotlight:
            postCombo(keyCode: 49, flags: .maskCommand)            // Cmd+Space
        case .lockScreen:
            postCombo(keyCode: 12, flags: [.maskControl, .maskCommand])  // Ctrl+Cmd+Q
        case .screenshotMenu:
            postCombo(keyCode: 23, flags: [.maskCommand, .maskShift])    // Cmd+Shift+5
        case .runShortcut:
            if let name = parameter, !name.isEmpty { runShortcut(named: name) }
        case .openApp:
            if let target = parameter, !target.isEmpty { openApp(target) }
        case .openURL:
            if let raw = parameter, let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Volume (CoreAudio, sandbox-safe)

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &device)
        return device
    }

    private func nudgeVolume(by delta: Float) {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var current: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &current) == noErr else { return }
        var next = max(0, min(1, current + delta))
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<Float>.size), &next)
        // Nudging out of silence should also unmute, like the keyboard key.
        if delta > 0 { setMuted(false) }
    }

    private func toggleMute() {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return }
        var next: UInt32 = muted == 0 ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &next)
    }

    private func setMuted(_ muted: Bool) {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Aux keys (media / brightness)

    /// Post a system-defined aux-key press + release (NX_KEYTYPE_*), the
    /// same events the keyboard's media row sends. Must run on a thread
    /// with an NSEvent-safe context, so hop to main.
    private func postAuxKey(_ keyType: Int32) {
        DispatchQueue.main.async {
            for down in [true, false] {
                let flags: NSEvent.ModifierFlags = down ? [] : []
                let data1 = Int((Int32(keyType) << 16) | (down ? 0x0A00 : 0x0B00))
                guard let event = NSEvent.otherEvent(
                    with: .systemDefined,
                    location: .zero,
                    modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    subtype: 8,
                    data1: data1,
                    data2: -1
                ), let cg = event.cgEvent else { continue }
                cg.setIntegerValueField(.eventSourceUserData,
                                        value: InputSimulator.ownEventMarker)
                cg.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: Key combos

    /// Post one full press + release of a keyboard combo, marked as our
    /// own so listen-only taps can filter it.
    /// Start or stop macOS dictation by pressing the dictation key itself.
    ///
    /// Measured from a physical F5 press on an Apple keyboard: the dictation
    /// key is NOT a HID consumer usage and NOT an NX special key. It is an
    /// ordinary key event with virtual keycode 176 carrying the Fn flag:
    ///
    ///     KEYDOWN virtualKeyCode=176 flags=0x800100
    ///
    /// so it can be posted like any other key. This works with Dictation's
    /// default shortcut (the microphone key), which means the user does not
    /// have to configure a custom shortcut first.
    private func startDictation() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: Self.dictationKeyCode, keyDown: down) else { continue }
            event.flags = [.maskSecondaryFn, .maskNonCoalesced]
            event.setIntegerValueField(.eventSourceUserData,
                                       value: InputSimulator.ownEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Apple's virtual keycode for the dictation / microphone key (F5).
    static let dictationKeyCode: CGKeyCode = 176

    private func postCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData,
                                       value: InputSimulator.ownEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Mac shortcuts

    private func openSystemApp(_ name: String) {
        let url = URL(fileURLWithPath: "/System/Applications/\(name).app")
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Automation

    /// Run a Siri Shortcut by name via the `shortcuts` CLI (silent, no UI).
    /// If the CLI is unavailable from the sandbox, fall back to the
    /// shortcuts:// URL scheme, which Shortcuts handles itself.
    private func runShortcut(named name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            task.arguments = ["run", name]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 { return }
                NSLog("[SystemAction] shortcuts run '%@' exited %d; falling back to URL scheme",
                      name, task.terminationStatus)
            } catch {
                NSLog("[SystemAction] shortcuts CLI unavailable (%@); falling back to URL scheme",
                      String(describing: error))
            }
            var comps = URLComponents(string: "shortcuts://run-shortcut")!
            comps.queryItems = [URLQueryItem(name: "name", value: name)]
            if let url = comps.url {
                // Run without stealing focus - the shortcut executes in the
                // background; the Shortcuts app stays wherever it was.
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url, configuration: config)
                }
            }
        }
    }

    /// The user's installed Shortcuts, for the picker in the binding
    /// editor. Cached for a few seconds so opening the menu twice doesn't
    /// spawn the CLI twice.
    private let shortcutsLock = NSLock()
    private var cachedShortcuts: [String] = []
    private var shortcutsFetchedAt: Date = .distantPast

    func installedShortcuts() -> [String] {
        shortcutsLock.lock()
        let fresh = Date().timeIntervalSince(shortcutsFetchedAt) < 10
        let cached = cachedShortcuts
        shortcutsLock.unlock()
        if fresh { return cached }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return cached }
            let names = text.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty }
            shortcutsLock.lock()
            cachedShortcuts = names
            shortcutsFetchedAt = Date()
            shortcutsLock.unlock()
            return names
        } catch {
            return cached
        }
    }

    private func openApp(_ target: String) {
        let config = NSWorkspace.OpenConfiguration()
        if target.hasPrefix("/") {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: target), configuration: config)
            return
        }
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            let path = "\(dir)/\(target).app"
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: path), configuration: config)
                return
            }
        }
        // Last try: treat the string as a bundle identifier.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }
}
