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
                // The bits CoreGraphics gave this key on its own (fn and
                // numeric-pad for the arrows and the keypad) are kept; every
                // other bit is written explicitly below. An event whose flags
                // are left unset inherits the HID system state, which after
                // a synthesized arrow still carries fn and numeric-pad, so a
                // Delete that followed an arrow became forward delete and a
                // Return became keypad Enter.
                let keyOwnBits = keyOwnFlagBits(virtualCode)
                if modifierFlags(for: hidCode) != nil {
                    // A modifier pressed on its own goes out as flagsChanged,
                    // which is what a physical keyboard sends. Posted as a
                    // keyDown it never reached apps that watch for a lone
                    // Option or Command tap (IME voice toggles, switchers).
                    // The flags are written explicitly, with the device bit
                    // that tells left Option from right, so the event matches
                    // the physical key it stands for.
                    event.type = .flagsChanged
                    flags.formUnion(deviceModifierBits())
                    flags.insert(.maskNonCoalesced)
                    event.flags = flags
                } else {
                    flags.formUnion(keyOwnBits)
                    flags.insert(.maskNonCoalesced)
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

        // Globe / fn is a pure modifier here. Posting a real fn key event would
        // trigger whatever single-press action the user has assigned to it, so
        // it only ever decorates the keys pressed alongside it.
        if hidCode == KeyCodeMap.globeFnCode { return }

        if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: false) {
                // Carry the still-held modifiers so releasing the letter of a
                // chord (e.g. the C of Cmd+C) does not read as a bare key-up.
                var flags = currentModifierFlags()
                let keyOwnBits = keyOwnFlagBits(virtualCode)
                if modifierFlags(for: hidCode) != nil {
                    // The release of a lone modifier: flagsChanged again, and
                    // the flags are written even when empty. Left unset, the
                    // event inherited the HID system state, where the key was
                    // still down, so apps saw two presses and no release.
                    event.type = .flagsChanged
                    flags.formUnion(deviceModifierBits())
                    flags.insert(.maskNonCoalesced)
                    event.flags = flags
                } else {
                    // Written even when empty, for the same reason as above.
                    flags.formUnion(keyOwnBits)
                    flags.insert(.maskNonCoalesced)
                    event.flags = flags
                }
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
    /// A source with no state of its own, used only to ask CoreGraphics which
    /// flag bits a key carries by itself (fn and numeric-pad for the arrows,
    /// fn for Home and End, numeric-pad for the keypad). Read off an event
    /// made with the real source, those bits are mixed with whatever the HID
    /// system state happens to hold, which is the pollution being avoided.
    private let probeSource = CGEventSource(stateID: .privateState)

    private func keyOwnFlagBits(_ virtualCode: Int) -> CGEventFlags {
        guard let e = CGEvent(keyboardEventSource: probeSource, virtualKey: CGKeyCode(virtualCode), keyDown: true) else { return [] }
        return e.flags.intersection([.maskSecondaryFn, .maskNumericPad])
    }

    /// The left/right device bits (the NX_DEVICE*KEYMASK values) for every
    /// modifier currently held, so a synthesized right Option carries the
    /// same bit a physical right Option does. Only flagsChanged events need
    /// them; ordinary key events carry the plain masks.
    private func deviceModifierBits() -> CGEventFlags {
        var bits: CGEventFlags = []
        for code in pressedKeys {
            switch code {
            case 224: bits.insert(CGEventFlags(rawValue: 0x0001))   // left control
            case 228: bits.insert(CGEventFlags(rawValue: 0x2000))   // right control
            case 225: bits.insert(CGEventFlags(rawValue: 0x0002))   // left shift
            case 229: bits.insert(CGEventFlags(rawValue: 0x0004))   // right shift
            case 226: bits.insert(CGEventFlags(rawValue: 0x0020))   // left option
            case 230: bits.insert(CGEventFlags(rawValue: 0x0040))   // right option
            case 227: bits.insert(CGEventFlags(rawValue: 0x0008))   // left command
            case 231: bits.insert(CGEventFlags(rawValue: 0x0010))   // right command
            default: break
            }
        }
        return bits
    }

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

    /// The height of the primary display, the one whose origin is (0, 0).
    /// `NSEvent.mouseLocation` is in the global bottom-left space anchored to
    /// that display, so the flip to CoreGraphics' top-left space must use its
    /// height. `NSScreen.main` is the screen with the key window, which on a
    /// second display of a different height put the flip off by the
    /// difference and walked the pointer to the top edge on every re-sync.
    /// The display rectangles in CoreGraphics (top-left origin) space.
    private func displayRectsCG() -> [CGRect] {
        guard let h = primaryScreenHeight else { return [] }
        return NSScreen.screens.map { sc in
            let f = sc.frame
            return CGRect(x: f.origin.x, y: h - f.origin.y - f.height, width: f.width, height: f.height)
        }
    }

    /// `point` if some display contains it; otherwise the point pulled back
    /// onto the edge of the display that held `previous` (or the nearest).
    private func clampedToDisplays(_ point: CGPoint, from previous: CGPoint) -> CGPoint {
        let rects = displayRectsCG()
        guard !rects.isEmpty else { return point }
        if rects.contains(where: { $0.contains(point) }) { return point }
        let home = rects.first(where: { $0.contains(previous) }) ?? rects.min(by: {
            hypot($0.midX - point.x, $0.midY - point.y) < hypot($1.midX - point.x, $1.midY - point.y)
        })!
        return CGPoint(x: min(max(point.x, home.minX), home.maxX - 1),
                       y: min(max(point.y, home.minY), home.maxY - 1))
    }

    private var primaryScreenHeight: CGFloat? {
        (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first)?.frame.height
    }

    /// Put the pointer at a fixed screen point (CoreGraphics coordinates,
    /// origin top-left) before a click, for auto-click rows parked on a
    /// button on screen. Posts a real move event so the app under the
    /// pointer sees the pointer arrive, then warps so the click lands there.
    func placePointer(atX x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        if let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                              mouseCursorPosition: point, mouseButton: .left) {
            taggedPost(move)
        }
        CGWarpMouseCursorPosition(point)
        trackedCursor = point
    }

    /// Move the pointer to the centre of whichever screen it is on, for the
    /// Center Pointer app action.
    func centerPointerOnCurrentScreen() {
        let loc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen, let h = primaryScreenHeight else { return }
        let f = screen.frame
        // AppKit is bottom-up; CG is top-down from the primary display.
        placePointer(atX: f.midX, y: h - f.midY)
    }

    /// Buttons this simulator can post: 0 left, 1 right, 2 middle, 3 to
    /// 31 the extra buttons a gaming mouse has. Anything else, including a
    /// negative index from a hand-edited preset, is refused up front rather
    /// than converted, since `UInt32(-1)` traps.
    private static func isPostableMouseButton(_ index: Int) -> Bool {
        (0...31).contains(index)
    }

    func mouseButtonDown(_ button: Int) {
        // Every early return must release the lock. An earlier version
        // returned with it held for any button past 2 (or with no screen
        // during sleep), which hung the pointer pump and then every later
        // press, and left the emergency stop unable to run.
        guard Self.isPostableMouseButton(button) else { return }
        mouseLock.lock()
        let alreadyDown = pressedMouseButtons.contains(button)
        if !alreadyDown { pressedMouseButtons.insert(button) }
        mouseLock.unlock()
        guard !alreadyDown else { return }

        // The screen list can be empty during sleep and wake; post from a
        // zero-height screen rather than skip, so the press still reaches
        // the front app and matches the release that will follow.
        let screenHeight = primaryScreenHeight ?? 0
        let location = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)
        postMouseButton(button, down: true, at: cgPoint)
    }

    func mouseButtonUp(_ button: Int) {
        guard Self.isPostableMouseButton(button) else { return }
        mouseLock.lock()
        let wasDown = pressedMouseButtons.remove(button) != nil
        mouseLock.unlock()
        guard wasDown else { return }

        // Always release, even with no screen, so a button never stays
        // physically down past a sleep.
        let screenHeight = primaryScreenHeight ?? 0
        let location = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)
        postMouseButton(button, down: false, at: cgPoint)
    }

    /// One button event. Left and right have their own event types; every
    /// other button is an "other" event carrying its number in the
    /// button-number field, which is how CoreGraphics addresses the extra
    /// buttons on a gaming mouse. Only 0, 1 and 2 exist as CGMouseButton
    /// values, so the old code could not represent button 3 at all.
    private func postMouseButton(_ button: Int, down: Bool, at point: CGPoint) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case 0: type = down ? .leftMouseDown : .leftMouseUp;   cgButton = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; cgButton = .center
        }
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: cgButton) else { return }
        if button >= 2 {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        }
        taggedPost(event)
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
    /// Guards the tracked-cursor state and the pressed-button set, which the
    /// motion pump reads from its own thread while the main thread presses
    /// and releases buttons.
    private let mouseLock = NSLock()

    func moveMouse(deltaX: Int, deltaY: Int) {
        mouseLock.lock(); defer { mouseLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        trackedFrames &+= 1
        if trackedCursor == nil || now - trackedAt > 0.1 {
            let location = NSEvent.mouseLocation
            if let h = primaryScreenHeight { cachedScreenHeight = h }
            if cachedScreenHeight == 0 { cachedScreenHeight = 1080 }
            trackedCursor = CGPoint(x: location.x, y: cachedScreenHeight - location.y)
        } else if trackedFrames % 16 == 0, let tracked = trackedCursor {
            // Periodic check against the real pointer. Adopt it only when it
            // has clearly moved on its own (the user touched the mouse, or a
            // screen edge stopped us); a difference of a pixel or two is
            // just the window server not having applied the last events yet,
            // and snapping to it every eighth frame put a visible hitch in
            // otherwise smooth motion.
            let location = NSEvent.mouseLocation
            if let h = primaryScreenHeight { cachedScreenHeight = h }
            let real = CGPoint(x: location.x, y: cachedScreenHeight - location.y)
            // The window server applies posted moves a little behind the
            // pump's 240 Hz, so the real pointer can trail by a few steps
            // without anything being wrong; only a clearly larger gap means
            // the pointer was moved by something else or stopped at an edge.
            if abs(real.x - tracked.x) > 64 || abs(real.y - tracked.y) > 64 {
                trackedCursor = real
            }
        }
        trackedAt = now
        var point = trackedCursor ?? .zero
        point.x += CGFloat(deltaX)
        point.y += CGFloat(deltaY)
        // Keep the tracked point on a display. Without this it runs on past
        // the edge while the real pointer sits at it, and the eventual resync
        // makes the pointer bounce back in from the edge.
        point = clampedToDisplays(point, from: trackedCursor ?? point)
        trackedCursor = point

        // A move while a mapped button is held must be a drag event, or
        // window moves, text selection, sliders and drag-and-drop never
        // happen: the system does not promote a plain move into a drag.
        let type: CGEventType
        let button: CGMouseButton
        var otherNumber: Int?
        if pressedMouseButtons.contains(0) {
            type = .leftMouseDragged; button = .left
        } else if pressedMouseButtons.contains(1) {
            type = .rightMouseDragged; button = .right
        } else if let other = pressedMouseButtons.first {
            type = .otherMouseDragged; button = .center; otherNumber = other
        } else {
            type = .mouseMoved; button = .left
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                               mouseCursorPosition: point, mouseButton: button) {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
            if let n = otherNumber { event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(n)) }
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
        // Every key goes out through keyUp, the one place that knows how to
        // release a modifier: a bare key-up event for Command or Shift
        // inherits the HID state where the key is still down, so the system
        // kept seeing the modifier held after the emergency stop, a sleep,
        // or a disconnect. Snapshot first, since keyUp mutates the set.
        // Held modifiers are released last so a letter in a chord is
        // released as the letter of that chord, the way a hand would do it.
        let held = pressedKeys.sorted { a, b in
            let aMod = modifierFlags(for: a) != nil
            let bMod = modifierFlags(for: b) != nil
            return !aMod && bMod
        }
        for key in held { keyUp(key) }
        pressedKeys.removeAll()

        // Snapshot under the lock, then release each through mouseButtonUp,
        // which posts the up event and drops the button from the set itself.
        mouseLock.lock()
        let heldButtons = pressedMouseButtons
        mouseLock.unlock()
        for button in heldButtons {
            mouseButtonUp(button)
        }
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
        if now != isTrusted {
            isTrusted = now
            if now {
                ActivityLog.shared.info("Permissions", "Accessibility access granted")
            } else {
                ActivityLog.shared.error("Permissions", "Accessibility access is missing: no key or mouse output can be sent until it is granted in System Settings, Privacy & Security, Accessibility")
            }
        }
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
        // The modern (Ventura+) pane URL, with the classic one as a fallback.
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(modern),
           let classic = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(classic)
        }
        startPolling()
    }

    /// Reveal the running copy of the app in the Finder, so it can be
    /// dragged into the Accessibility list when the switch will not stick.
    /// `Bundle.main` is wherever this build lives, so it is right for the
    /// App Store copy in Applications and for a development build alike.
    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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
    /// Back / Share / View / Minus: on every mainstream controller, rarely
    /// mapped, and never held down in a game. Home / PS is avoided because
    /// macOS Game Mode can swallow it before the app sees it.
    static let defaultControllerButton = 8
    /// Long enough that no game action ever holds the button this long.
    static let defaultHoldSeconds = 3.0

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
        else {
            ActivityLog.shared.warning("Emergency stop", "The shortcut \(s.displayString) is taken by another app; the keyboard emergency stop is off")
            return false
        }
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
            // 2. Let go of everything we are holding down, including the
            //    controller's motors and any light this app is holding: a
            //    stop that leaves a pad buzzing is not a stop.
            InputSimulator.shared.releaseAll()
            MIDIService.shared.releaseAllNotes()
            InProcessLightWriter.shared.stopMotors()
            MainActor.assumeIsolated { FeedbackService.shared.clearHapticEngines() }
            // 3. Give the pointer back. CursorGuardService is main-actor
            //    isolated and this block only ever runs on the main thread.
            MainActor.assumeIsolated {
                CursorGuardService.shared.clearPresetOverride()
                CursorGuardService.shared.forceShowCursor()
            }
            NSLog("InputConfig: emergency stop (\(reason.rawValue))")
            ActivityLog.shared.warning("Emergency stop", "Stopped everything: \(reason.rawValue)")
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
/// The Shortcuts and Applications lists, kept ready so a menu never has to
/// wait for them. Refreshed in the background when an editor row appears.
@MainActor
final class SystemListsCache: ObservableObject {
    static let shared = SystemListsCache()
    @Published fileprivate(set) var shortcuts: [String] = []
    @Published fileprivate(set) var apps: [String] = []
    fileprivate var loading = false
    fileprivate var loadedAt = Date.distantPast

    private init() {}

    func refreshIfStale() {
        guard !loading, Date().timeIntervalSince(loadedAt) > 30 else { return }
        loading = true
        SystemActionService.shared.loadLists { shortcuts, apps in
            MainActor.assumeIsolated {
                let cache = SystemListsCache.shared
                cache.shortcuts = shortcuts
                cache.apps = apps
                cache.loadedAt = Date()
                cache.loading = false
            }
        }
    }
}

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

    /// Applications the user can name in an Open App output: everything in
    /// the Applications folders plus whatever is running right now. Cached
    /// briefly because a menu asks for it on every open.
    private var cachedApps: [String] = []
    private var appsFetchedAt = Date.distantPast
    func installedApps() -> [String] {
        shortcutsLock.lock()
        let fresh = Date().timeIntervalSince(appsFetchedAt) < 30
        let cached = cachedApps
        shortcutsLock.unlock()
        if fresh, !cached.isEmpty { return cached }
        var names = Set<String>()
        let fm = FileManager.default
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"] {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                names.insert(String(item.dropLast(4)))
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let n = app.localizedName, !n.isEmpty { names.insert(n) }
        }
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        shortcutsLock.lock()
        cachedApps = sorted
        appsFetchedAt = Date()
        shortcutsLock.unlock()
        return sorted
    }

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

    /// Read the two lists off the main thread. Both are slow: the Shortcuts
    /// list runs `shortcuts list` as a subprocess, and the app list walks the
    /// Applications folders. Calling either while SwiftUI is building a menu
    /// blocked the main thread inside a view update and could re-enter it,
    /// which aborts the update outright. The menus read this cache instead.
    func loadLists(_ done: @escaping @Sendable ([String], [String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let shortcuts = self.installedShortcuts()
            let apps = self.installedApps()
            DispatchQueue.main.async { done(shortcuts, apps) }
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
