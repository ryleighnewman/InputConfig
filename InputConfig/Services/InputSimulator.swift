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
    /// Who holds each pressed key and button: a row's bindKey, its hold
    /// action or macro, or "" for callers that do not say. Two rows that
    /// both hold W keep it down until the second lets go; before, releasing
    /// either one released it for both. A repeat press by the same holder
    /// changes nothing, so a key can never be left counted down.
    private var keyHolders: [Int: Set<String>] = [:]
    private var mouseHolders: [Int: Set<String>] = [:]

    /// Cached event source for synthetic events. Created once on first
    /// access. Previously this was a computed property, which meant
    /// every key press / mouse motion / scroll wheel call paid the
    /// CGEventSource initialization cost. On a turbo-firing or
    /// joystick-as-mouse preset that was many hundreds of allocations
    /// per second.
    ///
    /// Made at init, not lazily: the motion pump's thread and the main
    /// thread could both touch a lazy property first and race to create it.
    private let eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)

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
    /// Posts at `.cghidEventTap`, so every app, games included, receives the
    /// event the way it receives one from a keyboard or mouse. macOS still
    /// requires the Accessibility permission for this app to post events;
    /// the app asks for it and explains why before any preset runs.
    /// When this app last posted each kind of event (system uptime), so Tap
    /// the Mac's typing guard can tell the app's own clicks and keys from a
    /// person's. Per kind: one shared time was overwritten by the mouse-up
    /// or pointer move that followed, and the app's own click then read as
    /// a person clicking.
    private static let lastPostLock = NSLock()
    nonisolated(unsafe) private static var lastPostAt: [UInt32: TimeInterval] = [:]
    static func lastPostUptime(of type: CGEventType) -> TimeInterval {
        lastPostLock.lock(); defer { lastPostLock.unlock() }
        return lastPostAt[type.rawValue] ?? 0
    }
    static func notePost(_ type: CGEventType) {
        lastPostLock.lock()
        lastPostAt[type.rawValue] = ProcessInfo.processInfo.systemUptime
        lastPostLock.unlock()
    }

    fileprivate func taggedPost(_ event: CGEvent) {
        Self.notePost(event.type)
        event.setIntegerValueField(.eventSourceUserData, value: Self.ownEventMarker)
        #if DEBUG
        if let sink = Self.debugEventSink { sink(event); return }
        #endif
        event.post(tap: .cghidEventTap)
    }

    #if DEBUG
    /// Tests only: when set, events are handed here instead of posted, so a
    /// test can read exactly what would have gone out without typing into or
    /// moving anything on the Mac. Never compiled into Release.
    nonisolated(unsafe) static var debugEventSink: ((CGEvent) -> Void)?
    #endif

    // MARK: - Keyboard Simulation

    /// Modifiers held by a row that presses nothing else: a button mapped to
    /// Shift or Command on its own, or a macro's Down step. Those combine
    /// with whatever else is pressed, the way a key held on a keyboard does.
    /// Kept per owner: a modifier first held alone and then also by a chord
    /// row stayed standalone after its lone row let go, so a third button
    /// pressed during the chord picked it up (Space became Command Space).
    private var standaloneModifiers: [Int: Set<String>] = [:]
    /// For each held key that is not a modifier, the modifiers of its own
    /// row (Command for a Command C row). Absent for a press from a caller
    /// that does not say (the test bench, drive mode), which keeps the old
    /// rule of taking every held modifier.
    private var keyScopes: [Int: Set<Int>] = [:]

    /// Press a key.
    ///
    /// `chord` is every key code of the row doing the pressing, its
    /// modifiers and its key together. With it, a key carries the modifiers
    /// of its own row plus any modifier a row holds on its own, and nothing
    /// else. Before, a key carried every modifier any row held: press a
    /// Command V button and, before letting go of it, a Space button, and
    /// the Space went out as Command Space, which opens Spotlight; a Return
    /// became Command Return. Quick presses across buttons came out as a
    /// jumble of shortcuts.
    /// The virtual key for a HID code. A letter in a Command or Control
    /// shortcut goes to the key that types that letter on the current
    /// layout, since macOS matches shortcuts by letter: posted by its US
    /// position, Select All was Command Q on a French keyboard and Undo was
    /// Command W. Plain keys and Option or Shift chords keep their position
    /// (games read keys by where they are).
    /// The same goes for the punctuation shortcuts (Command = and Command -
    /// for zoom, Command [ and ], Command comma for Settings, and so on):
    /// each goes to the key that types its character with Command on this
    /// layout, when there is one; one that needs Shift there keeps its
    /// position.
    ///
    /// With Settings, Keyboard output, "Keys follow the keyboard layout"
    /// on, a plain letter, digit or punctuation key goes to the key that
    /// types it on this layout too (on French AZERTY, A types a, not q),
    /// when the layout has an unshifted key for it; otherwise it keeps its
    /// position. Off by default: games read keys by position, so a WASD
    /// row stays on the same physical keys on every layout.
    private func virtualCode(for hidCode: Int, scope: Set<Int>?) -> Int? {
        let base = KeyCodeMap.hidToVirtualKeyCode[hidCode]
        let shortcut = scope.map { !$0.isDisjoint(with: Self.shortcutModifiers) } ?? false
        if shortcut, let character = Self.shortcutCharacter(hidCode) {
            if let known = layoutLetterKeys[hidCode] { return known ?? base }
            let found = SystemActionService.virtualKey(typing: character, command: true)
            layoutLetterKeys[hidCode] = .some(found)
            return found ?? base
        }
        guard !shortcut, UserDefaults.standard.bool(forKey: Self.followLayoutKey),
              let character = Self.shortcutCharacter(hidCode) ?? Self.digitCharacter(hidCode) else { return base }
        if let known = layoutPlainKeys[hidCode] { return known ?? base }
        let found = SystemActionService.virtualKey(typing: character)
        layoutPlainKeys[hidCode] = .some(found)
        return found ?? base
    }

    /// The setting that sends plain keys by what they type on the layout.
    nonisolated static let followLayoutKey = "InputConfig.keysFollowLayout"

    /// The digit a HID code types on a US keyboard (1 to 9, then 0).
    private static func digitCharacter(_ hidCode: Int) -> Character? {
        guard (30...39).contains(hidCode) else { return nil }
        return hidCode == 39 ? "0" : Character(String(hidCode - 29))
    }

    /// Each plain key's key on the current layout, found once per layout.
    private var layoutPlainKeys: [Int: Int?] = [:]

    /// The character a HID code types on a US keyboard, for the keys whose
    /// shortcuts macOS matches by character: the letters and the
    /// punctuation keys (not the ` key, whose window shortcut follows its
    /// position).
    private static func shortcutCharacter(_ hidCode: Int) -> Character? {
        if (4...29).contains(hidCode) { return Character(UnicodeScalar(UInt8(97 + hidCode - 4))) }
        let punctuation: [Int: Character] = [45: "-", 46: "=", 47: "[", 48: "]", 49: "\\", 51: ";",
                                             52: "'", 54: ",", 55: ".", 56: "/"]
        return punctuation[hidCode]
    }

    /// The virtual key each held key went down on, so it comes up on the
    /// same one: worked out again at release, a layout switched while the
    /// key was held sent the release to a different key and left the first
    /// one down.
    private var postedKeys: [Int: Int] = [:]

    /// Command and Control, left and right.
    private static let shortcutModifiers: Set<Int> = [224, 228, 227, 231]
    /// Each letter's key on the current layout, found once per layout.
    private var layoutLetterKeys: [Int: Int?] = [:]
    private var layoutObserver: NSObjectProtocol?

    private func watchLayout() {
        guard layoutObserver == nil else { return }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layoutLetterKeys.removeAll()
                self?.layoutPlainKeys.removeAll()
                EmergencyStopService.shared.refreshRegistration()
            }
        }
    }

    func keyDown(_ hidCode: Int, chord: [Int]? = nil, owner: String = "", repeats: Bool = false) {
        watchLayout()
        keyHolders[hidCode, default: []].insert(owner)
        let isModifier = modifierFlags(for: hidCode) != nil
        if repeats && !isModifier { repeatOwners[hidCode, default: []].insert(owner) }
        let scope: Set<Int>? = chord.map { Set($0.filter { self.modifierFlags(for: $0) != nil }) }
        // A modifier held by a switcher shortcut (Command Tab, Command `)
        // lends itself like one held alone: holding the switcher open and
        // pressing arrows or Return on other buttons is how it is used, and
        // the App Switcher preset depends on it, as in 1.5.
        if isModifier, chord.map({ keys in
            keys.allSatisfy { self.modifierFlags(for: $0) != nil } || keys.contains { Self.switcherKeys.contains($0) }
        }) ?? true {
            standaloneModifiers[hidCode, default: []].insert(owner)
        }
        if pressedKeys.contains(hidCode) {
            // Already down for another row. A second row pressing the same
            // key with other modifiers (Command Z held, Command Shift Z
            // pressed) still gets its shortcut: the key goes up and comes
            // down again with this row's modifiers. The same key with the
            // same modifiers (two buttons that both hold W) just stays down.
            // No stored scope (drive mode, the test bench) is the same as an
            // empty one: W held by drive mode and pressed by a plain W row
            // blipped up and down for nothing.
            guard !isModifier, let scope, (keyScopes[hidCode] ?? []) != scope,
                  hidCode != KeyCodeMap.globeFnCode,
                  let virtualCode = virtualCode(for: hidCode, scope: scope) else {
                // Held already by a row without repeat: this row's repeat
                // still starts, instead of being dropped.
                if repeats, !isModifier, repeatTimers[hidCode] == nil,
                   let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
                    startRepeat(hidCode, virtualCode: virtualCode)
                }
                return
            }
            postPlainKey(postedKeys[hidCode] ?? self.virtualCode(for: hidCode, scope: keyScopes[hidCode]) ?? virtualCode, down: false,
                         modifiers: scopedModifierFlags(keyScopes[hidCode]))
            keyScopes[hidCode] = scope
            postedKeys[hidCode] = virtualCode
            postPlainKey(virtualCode, down: true, modifiers: scopedModifierFlags(scope))
            return
        }
        pressedKeys.insert(hidCode)
        if !isModifier {
            if let scope { keyScopes[hidCode] = scope } else { keyScopes.removeValue(forKey: hidCode) }
        }

        // Globe / fn is a pure modifier here. Posting a real fn key event would
        // trigger whatever single-press action the user has assigned to it, so
        // it only ever decorates the keys pressed alongside it.
        if hidCode == KeyCodeMap.globeFnCode { return }

        if let virtualCode = virtualCode(for: hidCode, scope: scope) {
            if isModifier {
                postModifierChange(virtualCode, down: true)
            } else {
                postedKeys[hidCode] = virtualCode
                postPlainKey(virtualCode, down: true, modifiers: scopedModifierFlags(scope))
                if repeats { startRepeat(hidCode, virtualCode: virtualCode) }
            }
        } else {
            postSpecialKey(hidCode, keyDown: true)
        }
    }

    // MARK: Key repeat

    /// Held keys repeat like a real key does, after the Mac's own Delay
    /// Until Repeat and at its Key Repeat rate (Keyboard settings), so a
    /// D-pad on Down Arrow walks down a list and a button on Delete keeps
    /// deleting. Rows can turn it off for games that count repeats as
    /// presses. Repeats carry the autorepeat flag, as a keyboard's do.
    private var repeatTimers: [Int: DispatchSourceTimer] = [:]
    /// The rows that asked a held key to repeat. The repeat stops when the
    /// last of them lets go, even while a row set not to repeat still
    /// holds the key.
    private var repeatOwners: [Int: Set<String>] = [:]

    private func startRepeat(_ hidCode: Int, virtualCode: Int) {
        // One key repeats at a time, the last one pressed, as on a Mac
        // keyboard: a D-pad diagonal held on two arrows sent both,
        // interleaved.
        for (_, timer) in repeatTimers { timer.cancel() }
        repeatTimers.removeAll()
        let delay = max(0.1, NSEvent.keyRepeatDelay)
        let interval = max(0.015, NSEvent.keyRepeatInterval)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.pressedKeys.contains(hidCode),
                  let event = CGEvent(keyboardEventSource: self.eventSource,
                                      virtualKey: CGKeyCode(virtualCode), keyDown: true) else {
                self?.stopRepeat(hidCode)
                return
            }
            var flags = self.scopedModifierFlags(self.keyScopes[hidCode])
            flags.formUnion(self.keyOwnFlagBits(virtualCode))
            flags.insert(.maskNonCoalesced)
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            self.taggedPost(event)
        }
        repeatTimers[hidCode] = timer
        timer.resume()
    }

    private func stopRepeat(_ hidCode: Int) {
        repeatTimers.removeValue(forKey: hidCode)?.cancel()
    }

    func keyUp(_ hidCode: Int, owner: String = "") {
        guard pressedKeys.contains(hidCode) else { keyHolders.removeValue(forKey: hidCode); return }
        // This owner no longer holds it on its own, even if a chord row
        // keeps the key down below.
        if var lone = standaloneModifiers[hidCode] {
            lone.remove(owner)
            standaloneModifiers[hidCode] = lone.isEmpty ? nil : lone
        }
        if var repeaters = repeatOwners[hidCode] {
            repeaters.remove(owner)
            repeatOwners[hidCode] = repeaters.isEmpty ? nil : repeaters
            if repeaters.isEmpty { stopRepeat(hidCode) }
        }
        if var holders = keyHolders[hidCode] {
            holders.remove(owner)
            // Still held by another row: stays down.
            if !holders.isEmpty { keyHolders[hidCode] = holders; return }
            keyHolders.removeValue(forKey: hidCode)
        }
        repeatOwners.removeValue(forKey: hidCode)
        stopRepeat(hidCode)
        pressedKeys.remove(hidCode)
        let isModifier = modifierFlags(for: hidCode) != nil
        if isModifier { standaloneModifiers.removeValue(forKey: hidCode) }
        let scope = keyScopes.removeValue(forKey: hidCode)

        // Globe / fn is a pure modifier here. Posting a real fn key event would
        // trigger whatever single-press action the user has assigned to it, so
        // it only ever decorates the keys pressed alongside it.
        if hidCode == KeyCodeMap.globeFnCode { return }

        let posted = postedKeys.removeValue(forKey: hidCode)
        if let virtualCode = posted ?? virtualCode(for: hidCode, scope: scope) {
            if isModifier {
                // The release of a lone modifier: flagsChanged again, and the
                // flags are written even when empty. Left unset, the event
                // inherited the HID system state, where the key was still
                // down, so apps saw two presses and no release.
                postModifierChange(virtualCode, down: false)
            } else {
                // Carry the modifiers of its own row that are still held, so
                // releasing the C of Command C does not read as a bare key-up.
                postPlainKey(virtualCode, down: false, modifiers: scopedModifierFlags(scope))
            }
        } else {
            postSpecialKey(hidCode, keyDown: false)
        }
    }

    /// The modifier flags a key carries: every held modifier that belongs to
    /// its own row (`scope`) or is held on its own. A nil scope takes every
    /// held modifier, the rule for callers that do not say which row pressed.
    private func scopedModifierFlags(_ scope: Set<Int>?) -> CGEventFlags {
        var flags: CGEventFlags = []
        // A modifier in the row's own scope that the person is holding on
        // the keyboard (not this app): a Left Command row sending Command
        // Tab lets the finger supply the Command.
        if let scope {
            var physical: UInt64?
            for code in scope where !pressedKeys.contains(code) {
                guard let f = modifierFlags(for: code), let side = Self.deviceBit[code] else { continue }
                let held = physical ?? CGEventSource.flagsState(.hidSystemState).rawValue
                physical = held
                if held & side != 0 { flags.insert(f); flags.insert(CGEventFlags(rawValue: side)) }
            }
        }
        for code in pressedKeys {
            guard let f = modifierFlags(for: code) else { continue }
            if let scope, !scope.contains(code), standaloneModifiers[code] == nil { continue }
            flags.insert(f)
            // Which side, as a real keyboard's key events carry: apps that
            // tell Right Option from Left (iTerm2, VMs, remote desktops)
            // saw neither on the letter's own event.
            if let side = Self.deviceBit[code] { flags.insert(CGEventFlags(rawValue: side)) }
        }
        return flags
    }

    /// Tab and ` (Grave): the keys of the app and window switchers.
    private static let switcherKeys: Set<Int> = [43, 53]

    /// The NX_DEVICE bit of each side-specific modifier, by HID code.
    private static let deviceBit: [Int: UInt64] = [
        224: 0x0001, 228: 0x2000, 225: 0x0002, 229: 0x0004,
        226: 0x0020, 230: 0x0040, 227: 0x0008, 231: 0x0010,
    ]

    /// One ordinary key event with its flags written out in full.
    private func postPlainKey(_ virtualCode: Int, down: Bool, modifiers: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: down) else { return }
        // The bits CoreGraphics gave this key on its own (fn and numeric-pad
        // for the arrows and the keypad) are kept; every other bit is written
        // explicitly. An event whose flags are left unset inherits the HID
        // system state, which after a synthesized arrow still carries fn and
        // numeric-pad, so a Delete that followed an arrow became forward
        // delete and a Return became keypad Enter.
        var flags = modifiers
        flags.formUnion(keyOwnFlagBits(virtualCode))
        flags.insert(.maskNonCoalesced)
        event.flags = flags
        taggedPost(event)
    }

    /// A modifier going down or up. It goes out as flagsChanged, which is what
    /// a physical keyboard sends: posted as a keyDown it never reached apps
    /// that watch for a lone Option or Command tap (IME voice toggles,
    /// switchers). The flags are every modifier now held, with the device
    /// bit that tells left Option from right, so the event matches the
    /// physical key it stands for.
    private func postModifierChange(_ virtualCode: Int, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: down) else { return }
        event.type = .flagsChanged
        var flags = currentModifierFlags()
        flags.formUnion(deviceModifierBits())
        flags.insert(.maskNonCoalesced)
        event.flags = flags
        taggedPost(event)
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
            // Typed text carries no modifiers. Left unset, the flags came from
            // the HID system state, so text typed while a Command shortcut was
            // still held on another button went out as Command A, Select All.
            if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.flags = [.maskNonCoalesced]
                taggedPost(down)
            }
            if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.flags = [.maskNonCoalesced]
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
        // NX_KEYTYPE values from IOKit's ev_keymap.h. Brightness was 0x91
        // and 0x90, which are not key types, so it did nothing.
        71: 3,      // Brightness Down (NX_KEYTYPE_BRIGHTNESS_DOWN)
        72: 2,      // Brightness Up (NX_KEYTYPE_BRIGHTNESS_UP)
        305: 22,    // Keyboard Light Down (NX_KEYTYPE_ILLUMINATION_DOWN)
        306: 21,    // Keyboard Light Up (NX_KEYTYPE_ILLUMINATION_UP)
        313: 14,    // Eject (NX_KEYTYPE_EJECT)
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

    /// The pointer's position in CoreGraphics' global space (origin at the
    /// top left of the primary display), the space every posted mouse event
    /// uses. Read from CoreGraphics rather than flipped from
    /// `NSEvent.mouseLocation`, so no screen height is involved (a second
    /// display of a different height once put the flip off and walked the
    /// pointer to the top edge), and it is safe on the motion pump's thread.
    private func pointerLocationCG() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// The display rectangles in the same space, from CoreGraphics, which is
    /// safe off the main thread. The pump used to ask NSScreen for them on
    /// its own queue on every move: AppKit does not promise that works off
    /// the main thread, an empty answer skipped the edge clamp entirely (a
    /// pointer that ran off the screen and would not come back), and the
    /// lookup at up to 125 Hz was CPU for nothing. Cached now, re-read when
    /// the arrangement changes and every two seconds, and never replaced by
    /// an empty list, so the clamp always has a screen to hold the pointer to.
    private let displayLock = NSLock()
    private var displayCache: [CGRect] = []
    private var displayCacheAt: TimeInterval = 0
    private var displaysChanged = true
    private var displayObserver: NSObjectProtocol?

    private func displayRectsCG() -> [CGRect] {
        displayLock.lock(); defer { displayLock.unlock() }
        if displayObserver == nil {
            displayObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.displayLock.lock()
                self.displaysChanged = true
                self.displayLock.unlock()
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if displaysChanged || displayCache.isEmpty || now - displayCacheAt > 2 {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            if CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 {
                displayCache = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
                displaysChanged = false
            }
            displayCacheAt = now
        }
        return displayCache
    }

    /// `point` if some display contains it; otherwise the point pulled back
    /// onto the edge of the display that held `previous` (or the nearest).
    private func clampedToDisplays(_ point: CGPoint, from previous: CGPoint) -> CGPoint {
        var rects = displayRectsCG()
        if rects.isEmpty {
            // No list yet (the very first read failed): hold the pointer to
            // the main display rather than letting it run off every screen,
            // where it turns invisible until the real mouse is moved.
            let main = CGDisplayBounds(CGMainDisplayID())
            if main.width > 1, main.height > 1 { rects = [main] }
        }
        guard !rects.isEmpty else { return point }
        if rects.contains(where: { $0.contains(point) }) { return point }
        let home = rects.first(where: { $0.contains(previous) }) ?? rects.min(by: {
            hypot($0.midX - point.x, $0.midY - point.y) < hypot($1.midX - point.x, $1.midY - point.y)
        })!
        return CGPoint(x: min(max(point.x, home.minX), home.maxX - 1),
                       y: min(max(point.y, home.minY), home.maxY - 1))
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
        // Re-associated, as in warpPointer: a bare warp froze the physical
        // mouse for a quarter second on every fixed-point auto-click pulse.
        CGAssociateMouseAndMouseCursorPosition(1)
        // Under the lock the motion pump reads it with, and stamped, so the
        // pump continues from here instead of re-reading a stale position.
        mouseLock.lock()
        trackedCursor = point
        trackedAt = ProcessInfo.processInfo.systemUptime
        mouseLock.unlock()
    }

    /// Put the pointer somewhere without a move event (confine, recenter).
    /// Through here rather than a bare CGWarpMouseCursorPosition: the pump's
    /// next stick or gyro move carried on from the old tracked point and
    /// undid the warp, and a warp freezes the physical mouse for about a
    /// quarter second unless the mouse is re-associated with the cursor.
    func warpPointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        mouseLock.lock()
        trackedCursor = point
        trackedAt = ProcessInfo.processInfo.systemUptime
        mouseLock.unlock()
    }

    /// Move the pointer to the center of whichever screen it is on, for the
    /// Center Pointer app action and every motion re-zero. Returns where it
    /// put the pointer, or nil when no display is known.
    @discardableResult
    func centerPointerOnCurrentScreen() -> CGPoint? {
        guard let center = Self.recenterPoint(pointer: pointerLocationCG(), displays: displayRectsCG()) else {
            return nil
        }
        placePointer(atX: Double(center.x), y: Double(center.y))
        return center
    }

    /// The center of the display that holds `pointer`. Both are in
    /// CoreGraphics' global space (origin at the top left of the primary
    /// display, y growing down, as `CGDisplayBounds` and `CGEvent.location`
    /// report it), so no AppKit flip is involved. A pointer on a display's
    /// bottom or right edge, which `CGRect.contains` leaves out, or one just
    /// off every display, belongs to the nearest display, never to the
    /// first one in the list: falling back to the first sent the re-center
    /// to the primary monitor from a pointer on a second one.
    nonisolated static func recenterPoint(pointer: CGPoint, displays: [CGRect]) -> CGPoint? {
        let usable = displays.filter { $0.width > 1 && $0.height > 1 }
        guard !usable.isEmpty else { return nil }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - pointer.x, 0, pointer.x - r.maxX)
            let dy = max(r.minY - pointer.y, 0, pointer.y - r.maxY)
            return hypot(dx, dy)
        }
        let screen = usable.first(where: { $0.contains(pointer) })
            ?? usable.min(by: { distance($0) < distance($1) })!
        // Whole points, so the pointer lands on the same spot every time.
        return CGPoint(x: (screen.midX).rounded(.down), y: (screen.midY).rounded(.down))
    }

    /// Buttons this simulator can post: 0 left, 1 right, 2 middle, 3 to
    /// 31 the extra buttons a gaming mouse has. Anything else, including a
    /// negative index from a hand-edited preset, is refused up front rather
    /// than converted, since `UInt32(-1)` traps.
    private static func isPostableMouseButton(_ index: Int) -> Bool {
        (0...31).contains(index)
    }

    /// Click counting. Posted mouse events carry a click count of 1 unless it
    /// is set, and apps read double and triple clicks from that count
    /// (NSEvent.clickCount), not from the timing, so two quick synthesized
    /// clicks reached them as two single clicks: a Double click row, or two
    /// quick presses of a Click button, did not open a file in Finder.
    private var lastClickButton = -1
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var lastClickCount = 0
    /// The count each held button was pressed with, for its release and drags.
    private var pressedClickCounts: [Int: Int] = [:]

    /// `singleClick`: a turbo or auto-click pulse. Each is its own click,
    /// never part of a double click, or an auto-clicker at 10 a second sent
    /// click 2, 3, 4 and up and opened files and selected words.
    func mouseButtonDown(_ button: Int, owner: String = "", singleClick: Bool = false) {
        // Every early return must release the lock. An earlier version
        // returned with it held for any button past 2 (or with no screen
        // during sleep), which hung the pointer pump and then every later
        // press, and left the emergency stop unable to run.
        guard Self.isPostableMouseButton(button) else { return }
        // CoreGraphics answers even during sleep and wake, so the press
        // always reaches the front app and matches the release that follows.
        let point = pointerLocationCG()
        let now = ProcessInfo.processInfo.systemUptime
        let interval = NSEvent.doubleClickInterval
        mouseLock.lock()
        mouseHolders[button, default: []].insert(owner)
        let alreadyDown = pressedMouseButtons.contains(button)
        var count = 1
        if !alreadyDown {
            pressedMouseButtons.insert(button)
            // The next click of a double or triple click: same button, soon
            // enough for the system's double-click speed, about the same spot.
            // A triple click is the most any app reads; a fourth starts over.
            if !singleClick, button == lastClickButton, now - lastClickTime <= interval,
               abs(point.x - lastClickPoint.x) <= 4, abs(point.y - lastClickPoint.y) <= 4 {
                count = lastClickCount >= 3 ? 1 : lastClickCount + 1
            }
            lastClickButton = button
            // A turbo or auto-click pulse never starts a chain either, or the
            // next ordinary click at that spot went out as a double click.
            lastClickTime = singleClick ? 0 : now
            lastClickPoint = point
            lastClickCount = count
            pressedClickCounts[button] = count
        }
        mouseLock.unlock()
        guard !alreadyDown else { return }
        postMouseButton(button, down: true, at: point, clickCount: count)
    }

    func mouseButtonUp(_ button: Int, owner: String = "") {
        guard Self.isPostableMouseButton(button) else { return }
        mouseLock.lock()
        if var holders = mouseHolders[button], pressedMouseButtons.contains(button) {
            holders.remove(owner)
            // Still held by another row, for example the other half of a drag.
            if !holders.isEmpty { mouseHolders[button] = holders; mouseLock.unlock(); return }
        }
        mouseHolders.removeValue(forKey: button)
        let wasDown = pressedMouseButtons.remove(button) != nil
        let count = pressedClickCounts.removeValue(forKey: button) ?? 1
        mouseLock.unlock()
        guard wasDown else { return }

        // Always release, even with no screen, so a button never stays
        // physically down past a sleep.
        postMouseButton(button, down: false, at: pointerLocationCG(), clickCount: count)
    }

    /// One button event. Left and right have their own event types; every
    /// other button is an "other" event carrying its number in the
    /// button-number field, which is how CoreGraphics addresses the extra
    /// buttons on a gaming mouse. Only 0, 1 and 2 exist as CGMouseButton
    /// values, so the old code could not represent button 3 at all.
    private func postMouseButton(_ button: Int, down: Bool, at point: CGPoint, clickCount: Int) {
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
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        taggedPost(event)
    }

    // MARK: - Mouse Motion Simulation

    /// Cursor position we last posted, so continuous motion does not ask the
    /// window server where the cursor is on every poll frame (that call plus
    /// the screen lookup was the cost behind "Variable Sensitivity spikes
    /// the CPU"). Re-read from the system after an idle gap, when the user
    /// may have moved the real mouse, and every 16th move so the tracked
    /// point cannot drift from the real one for long.
    private var trackedCursor: CGPoint?
    private var trackedAt: TimeInterval = 0
    private var trackedFrames = 0
    /// Guards the tracked-cursor state and the pressed-button set, which the
    /// motion pump reads from its own thread while the main thread presses
    /// and releases buttons.
    private let mouseLock = NSLock()

    func moveMouse(deltaX: Int, deltaY: Int) {
        mouseLock.lock(); defer { mouseLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        trackedFrames &+= 1
        if trackedCursor == nil || now - trackedAt > 0.1 {
            trackedCursor = pointerLocationCG()
        } else if trackedFrames % 16 == 0, let tracked = trackedCursor {
            // Periodic check against the real pointer. Adopt it only when it
            // has clearly moved on its own (the user touched the mouse, or a
            // screen edge stopped us); a difference of a pixel or two is
            // just the window server not having applied the last events yet,
            // and snapping to it every eighth frame put a visible hitch in
            // otherwise smooth motion.
            let real = pointerLocationCG()
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
        var heldButton: Int?
        if pressedMouseButtons.contains(0) {
            type = .leftMouseDragged; button = .left; heldButton = 0
        } else if pressedMouseButtons.contains(1) {
            type = .rightMouseDragged; button = .right; heldButton = 1
        } else if let other = pressedMouseButtons.first {
            type = .otherMouseDragged; button = .center; otherNumber = other; heldButton = other
        } else {
            type = .mouseMoved; button = .left
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                               mouseCursorPosition: point, mouseButton: button) {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
            if let n = otherNumber { event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(n)) }
            // A drag carries the count of the press that started it, so a
            // double click held and dragged selects word by word, as with a mouse.
            if let held = heldButton, let n = pressedClickCounts[held] {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            }
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

    /// One wheel notch, posted in line units like a real notched wheel.
    /// A 5-pixel scroll read back as continuous (trackpad-style) scrolling,
    /// which games that count notches, such as weapon switching, ignore.
    /// Same sign as before, so presets keep their direction.
    /// One wheel notch, a line each, so games that count notches see them.
    /// `lines` carries the preset's Scroll speed, which these rows ignored.
    func scrollWheelStep(axis: MouseAxis, direction: MouseDirection, lines: Int = 1) {
        let count = Int32(max(1, min(20, lines)))
        let delta: Int32 = direction == .positive ? count : -count
        let vertical = axis == .vertical
        if let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .line,
                               wheelCount: 2, wheel1: vertical ? delta : 0,
                               wheel2: vertical ? 0 : delta, wheel3: 0) {
            taggedPost(event)
        }
    }

    // MARK: - Release All

    func releaseAll() {
        // A forced release is never the first half of a double click: the
        // next press after a preset switch or a pause goes out as click 1.
        defer { lastClickTime = 0 }
        // Every key goes out through keyUp, the one place that knows how to
        // release a modifier: a bare key-up event for Command or Shift
        // inherits the HID state where the key is still down, so the system
        // kept seeing the modifier held after the emergency stop, a sleep,
        // or a disconnect. Snapshot first, since keyUp mutates the set.
        // Held modifiers are released last so a letter in a chord is
        // released as the letter of that chord, the way a hand would do it.
        // Everyone lets go at once: clear the holders first, or keyUp
        // would keep a key down for a row that still claims it.
        // Mouse buttons go first, before any modifier: an Option drag lets
        // go of the button before Option, so a copy is not dropped as a
        // move. Snapshot under the lock, then release each through
        // mouseButtonUp, which posts the up event and drops the button
        // from the set itself.
        mouseLock.lock()
        mouseHolders.removeAll()
        let heldButtons = pressedMouseButtons
        mouseLock.unlock()
        for button in heldButtons {
            mouseButtonUp(button)
        }

        keyHolders.removeAll()
        repeatOwners.removeAll()
        for timer in repeatTimers.values { timer.cancel() }
        repeatTimers.removeAll()
        let held = pressedKeys.sorted { a, b in
            let aMod = modifierFlags(for: a) != nil
            let bMod = modifierFlags(for: b) != nil
            return !aMod && bMod
        }
        for key in held { keyUp(key) }
        pressedKeys.removeAll()
        keyScopes.removeAll()
        postedKeys.removeAll()
        standaloneModifiers.removeAll()
    }

    /// After a crash or force quit, a modifier or mouse button this app was
    /// holding stays down system-wide (Command held forever, a stuck drag),
    /// and a relaunch did not clear it. Let go of any that the system still
    /// reports down. Called once at launch when the last run ended with a
    /// preset running.
    func releaseLeftoversFromLastRun() {
        let modifiers: [CGKeyCode] = [56, 60, 59, 62, 58, 61, 55, 54, 63]
        for vk in modifiers where CGEventSource.keyState(.combinedSessionState, key: vk) {
            if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: vk, keyDown: false) {
                up.type = .flagsChanged
                up.flags = []
                taggedPost(up)
            }
        }
        // Ordinary keys too (a game preset holding W), and every mouse
        // button, side buttons included.
        let modifierSet = Set(modifiers)
        for vk in Set(KeyCodeMap.hidToVirtualKeyCode.values) where !modifierSet.contains(CGKeyCode(vk))
            && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(vk)) {
            if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(vk), keyDown: false) {
                up.flags = []
                taggedPost(up)
            }
        }
        let point = pointerLocationCG()
        for number in 0..<32 {
            guard let button = CGMouseButton(rawValue: UInt32(number)),
                  CGEventSource.buttonState(.combinedSessionState, button: button) else { continue }
            let type: CGEventType = number == 0 ? .leftMouseUp : (number == 1 ? .rightMouseUp : .otherMouseUp)
            if let up = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                mouseCursorPosition: point, mouseButton: button) {
                up.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
                taggedPost(up)
            }
        }
    }

    /// True while this app holds the key down itself. Read on the main
    /// thread, where keys are pressed and released.
    func isHolding(_ hidCode: Int) -> Bool { pressedKeys.contains(hidCode) }

    /// The side bits of the modifiers this app holds, as posted on its
    /// own events; the input poll masks them out of the session's flags.
    func ownDeviceModifierBits() -> UInt { UInt(deviceModifierBits().rawValue) }

    /// Let go of what owners starting with `prefix` hold (a controller group's
    /// rows, "2:" for group 2). A key or button another owner still holds
    /// stays down.
    func releaseOwners(withPrefix prefix: String) {
        // Buttons, then keys, then modifiers, the order a hand lets go in.
        mouseLock.lock()
        let buttons = mouseHolders.filter { $0.value.contains(where: { $0.hasPrefix(prefix) }) }
        mouseLock.unlock()
        for (button, holders) in buttons {
            for owner in holders where owner.hasPrefix(prefix) { mouseButtonUp(button, owner: owner) }
        }
        let keys = keyHolders.filter { $0.value.contains(where: { $0.hasPrefix(prefix) }) }
            .sorted { a, b in modifierFlags(for: a.key) == nil && modifierFlags(for: b.key) != nil }
        for (code, holders) in keys {
            for owner in holders where owner.hasPrefix(prefix) { keyUp(code, owner: owner) }
        }
    }

    #if DEBUG
    /// How many keys the simulator currently holds down. Used by the smoke
    /// test to prove the emergency stop actually let go of them.
    var debugHeldKeyCount: Int { pressedKeys.count + pressedMouseButtons.count }
    #endif
}

/// Tracks and helps the user grant the macOS Accessibility permission,
/// which InputConfig needs to deliver the keyboard and mouse actions a
/// user maps to their controller. The same permission lets the app watch
/// the keyboard and mouse while a preset, Scan, or the Live Visualizer uses
/// them as inputs; nothing is recorded or sent anywhere.
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
        // The system announces Accessibility list changes on this
        // distributed notification. The trust state lags it slightly, so
        // look again a moment later too.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.refresh()
            }
        }
        // While a preset runs, check every 10 s, so a revoke made while the
        // app sits in the background is noticed and logged instead of
        // every output silently going nowhere.
        NotificationCenter.default.addObserver(
            forName: MappingEngine.didStartNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setRunningWatch(true) }
        }
        NotificationCenter.default.addObserver(
            forName: MappingEngine.didStopNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setRunningWatch(false) }
        }
    }

    private var runningWatch: Timer?

    private func setRunningWatch(_ on: Bool) {
        runningWatch?.invalidate()
        runningWatch = nil
        guard on else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 2
        runningWatch = timer
        RunLoop.main.add(timer, forMode: .common)
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
    private var chords: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
    /// Chords let go while a shortcut recorder listens; they come back on resume.
    private var suspended: Set<UInt32> = []
    private var suspendDepth = 0
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
        // While a recorder listens, a new chord waits for the resume like
        // the others; registered live, a preset could take the emergency
        // stop's chord while it was let go.
        if suspendDepth > 0 {
            chords[id] = (keyCode, modifiers)
            actions[id] = action
            suspended.insert(id)
            return id
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A4B4350), id: id)  // 'JKCP'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("HotKeyCenter: RegisterEventHotKey failed (status \(status)); the chord may be taken by another app")
            return nil
        }
        refs[id] = ref
        chords[id] = (keyCode, modifiers)
        actions[id] = action
        return id
    }

    func unregister(_ token: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if let ref = refs.removeValue(forKey: token) { UnregisterEventHotKey(ref) }
        actions.removeValue(forKey: token)
        chords.removeValue(forKey: token)
        suspended.remove(token)
    }

    /// Let go of every chord while a shortcut recorder listens. A registered
    /// hot key never reaches the app as a key press, so recording one of
    /// InputConfig's own chords ran its action (a stop, a preset switch)
    /// instead of reaching the recorder and its refusal message.
    func suspendAll() {
        lock.lock()
        defer { lock.unlock() }
        suspendDepth += 1
        guard suspendDepth == 1 else { return }
        for (id, ref) in refs {
            UnregisterEventHotKey(ref)
            suspended.insert(id)
        }
        refs.removeAll()
    }

    /// Take the chords back, each under its old ID so its action still fires.
    /// `first` are taken back before the rest (the emergency stop's). The
    /// IDs that could not be taken back are returned and kept in
    /// `lostOnResume`.
    @discardableResult
    func resumeAll(first: Set<UInt32> = []) -> Set<UInt32> {
        lock.lock()
        defer { lock.unlock() }
        guard suspendDepth > 0 else { return [] }
        suspendDepth -= 1
        guard suspendDepth == 0 else { return [] }
        var failed = Set<UInt32>()
        let order = suspended.sorted { a, b in first.contains(a) && !first.contains(b) }
        for id in order {
            guard let c = chords[id] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(c.keyCode, c.modifiers,
                                             EventHotKeyID(signature: OSType(0x4A4B4350), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
            } else {
                NSLog("HotKeyCenter: could not take a chord back after recording (status \(status))")
                failed.insert(id)
                actions.removeValue(forKey: id)
                chords.removeValue(forKey: id)
            }
        }
        suspended.removeAll()
        lostOnResume = failed
        return failed
    }

    /// Chords whose registration failed when a recorder let them go again.
    private(set) var lostOnResume: Set<UInt32> = []

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
    /// A plain key, Shift with a key that types (Shift slash is "?"), or
    /// Option with one (Option E is the accent key, and on a German layout
    /// Option L is @): a hot key takes that character away from every app.
    var stealsATypingKey: Bool {
        let typingMods: Set<UInt32> = [0, UInt32(shiftKey), UInt32(optionKey), UInt32(optionKey | shiftKey)]
        guard typingMods.contains(modifiers) else { return false }
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
        // A punctuation key by what it types on the current layout: the
        // period key of a US keyboard is the semicolon of a French one.
        if [kVK_ANSI_Period, kVK_ANSI_Comma, kVK_ANSI_Slash].contains(Int(code)),
           let typed = SystemActionService.character(forVirtualKey: Int(code)) {
            return typed
        }
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
    /// The default hold is Back and Start together: Back alone is bound in
    /// Easy Browse and every game preset, and a slow press of it (common with
    /// limited motor control) stopped the preset with no warning.
    static let withStartKey     = "InputConfig.panicControllerWithStart"
    static let startButton = 9

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
    private var shiftToken: UInt32?
    private(set) var isRegistered = false
    /// The stop's hot-key IDs, which a recorder takes back first.
    var tokens: Set<UInt32> { Set([token, shiftToken].compactMap { $0 }) }

    private init() {}

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: true,
            keyCodeKey: Int(defaultSpec.keyCode),
            modifiersKey: Int(defaultSpec.modifiers),
            controllerKey: true,
            controllerBtnKey: defaultControllerButton,
            holdSecondsKey: defaultHoldSeconds,
            withStartKey: true,
        ])
    }

    var spec: HotKeySpec {
        let d = UserDefaults.standard
        // UInt32(exactly:): a negative or huge stored value (a hand-edited
        // plist or an odd backup) trapped here on every launch.
        let code = (d.object(forKey: Self.keyCodeKey) as? Int).flatMap { UInt32(exactly: $0) }
        let mods = (d.object(forKey: Self.modifiersKey) as? Int).flatMap { UInt32(exactly: $0) }
        let stored = HotKeySpec(keyCode: code ?? Self.defaultSpec.keyCode,
                                modifiers: mods ?? Self.defaultSpec.modifiers)
        // The default chord is on whatever key types a period on this
        // layout (help and Settings call it period); on AZERTY, Dvorak and
        // Turkish the US period position types something else.
        if stored == Self.defaultSpec,
           let period = SystemActionService.virtualKey(typing: ".", command: true), period != Int(Self.defaultSpec.keyCode) {
            return HotKeySpec(keyCode: UInt32(period), modifiers: stored.modifiers)
        }
        return stored
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // The engine asks for these on every poll frame, so they are cached in
    // memory rather than read from UserDefaults each time. A preference read
    // walks the CFPreferences search list, which was costing a third of the
    // poll loop at 120 Hz. Refreshed whenever defaults change.
    private var cachedHoldEnabled = true
    private var cachedButton = EmergencyStopService.defaultControllerButton
    private var cachedHoldSeconds = EmergencyStopService.defaultHoldSeconds
    private var cachedWithStart = true
    private var defaultsObserver: NSObjectProtocol?

    var controllerHoldEnabled: Bool { cachedHoldEnabled }
    var controllerButton: Int { cachedButton }
    var holdSeconds: Double { cachedHoldSeconds }
    /// Whether the hold needs Start (9) held with the button: on by default
    /// for the default button, off for any button picked in Settings.
    var holdNeedsStart: Bool { cachedWithStart && cachedButton == Self.defaultControllerButton }

    /// Pull the controller-hold settings into memory. Called at registration
    /// and whenever any default changes.
    func refreshCachedSettings() {
        let d = UserDefaults.standard
        cachedHoldEnabled = d.bool(forKey: Self.controllerKey)
        cachedButton = (d.object(forKey: Self.controllerBtnKey) as? Int)
            ?? Self.defaultControllerButton
        cachedWithStart = d.bool(forKey: Self.withStartKey)
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
        if let t = shiftToken { HotKeyCenter.shared.unregister(t); shiftToken = nil }
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
        // A preset holding Shift (a sprint toggle) adds Shift to the chord,
        // and hot keys match their modifiers exactly, so the same chord with
        // Shift stops too. Best effort: it may be taken by another app.
        if s.modifiers & UInt32(shiftKey) == 0 {
            shiftToken = HotKeyCenter.shared.register(keyCode: s.keyCode, modifiers: s.modifiers | UInt32(shiftKey),
                                                      action: { EmergencyStopService.shared.stop(reason: .hotkey) })
        }
        isRegistered = true
        // Registered now, so a later conflict on the same chord warns again.
        UserDefaults.standard.removeObject(forKey: "InputConfig.emergencyStopWarnedChord")
        return true
    }

    /// The chord plus Shift, also registered while the chord has no Shift
    /// of its own. Nil when the chord already includes Shift.
    var shiftVariant: HotKeySpec? {
        let s = spec
        guard s.modifiers & UInt32(shiftKey) == 0 else { return nil }
        return HotKeySpec(keyCode: s.keyCode, modifiers: s.modifiers | UInt32(shiftKey))
    }

    /// True when the chord, or its Shift variant, is exactly this one.
    func claims(_ other: HotKeySpec) -> Bool {
        other == spec || other == shiftVariant
    }

    /// A preset's own shortcut wins over the extra Shift chord: the stop
    /// registers first at launch, which took that preset's shortcut away.
    @discardableResult
    func yieldShiftVariant(to other: HotKeySpec) -> Bool {
        guard let t = shiftToken, other == shiftVariant else { return false }
        HotKeyCenter.shared.unregister(t)
        shiftToken = nil
        return true
    }

    /// Record a new chord and switch the keyboard stop on with it. When the
    /// chord cannot be registered, the previous chord and switch come back.
    @discardableResult
    func trySpec(_ newSpec: HotKeySpec) -> Bool {
        let d = UserDefaults.standard
        let previous = spec
        let wasEnabled = isEnabled
        d.set(Int(newSpec.keyCode), forKey: Self.keyCodeKey)
        d.set(Int(newSpec.modifiers), forKey: Self.modifiersKey)
        d.set(true, forKey: Self.enabledKey)
        if refreshRegistration() { return true }
        d.set(Int(previous.keyCode), forKey: Self.keyCodeKey)
        d.set(Int(previous.modifiers), forKey: Self.modifiersKey)
        d.set(wasEnabled, forKey: Self.enabledKey)
        refreshRegistration()
        return false
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
        // Heard and spoken, so a stop is never silent; from the controller,
        // also how to start again.
        DispatchQueue.main.async {
            NSSound(named: "Funk")?.play()
            let said = reason == .controllerHold
                ? "Stopped by the controller hold. Hold it again to start the preset back up."
                : "Emergency stop. Everything stopped."
            AccessibilityNotification.Announcement(said).post()
        }
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
            MainActor.assumeIsolated { RawHIDGamepadService.shared.stopSteamController2026Rumble() }
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
            } else if EmergencyStopService.shared.yieldShiftVariant(to: spec),
                      let token = HotKeyCenter.shared.register(
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
    /// The stop's chord counts even while its switch is off, so turning it
    /// back on cannot find a preset sitting on it.
    static func conflicts(for spec: HotKeySpec, excluding presetID: UUID?,
                          in presets: [Preset]) -> Bool {
        if EmergencyStopService.shared.spec == spec { return true }
        if GlobalHotKeyService.shared.isEnabled, spec == GlobalHotKeyService.spec { return true }
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

    /// Each press of the shortcut, numbered. Two listeners (the main window
    /// and the menu bar) can both hear one press; only the first to claim it
    /// acts. With the app hidden, both toggled, so the preset went on and
    /// straight back off. Main thread only.
    nonisolated(unsafe) static var pressSerial = 0
    nonisolated(unsafe) private static var claimedSerial = 0

    /// True for the first listener to ask about this press.
    static func claim(_ note: Notification) -> Bool {
        let serial = (note.object as? NSNumber)?.intValue ?? 0
        guard serial == 0 || serial != claimedSerial else { return false }
        claimedSerial = serial
        return true
    }

    /// Human-readable chord, shown in Settings.
    let shortcutDescription = "Control + Option + Command + P"
    /// The fixed chord, so the emergency stop recorder can refuse it.
    static let spec = HotKeySpec(keyCode: UInt32(kVK_ANSI_P),
                                 modifiers: UInt32(controlKey | optionKey | cmdKey))

    private init() {}

    /// Returns false when registration fails (typically because another app
    /// owns the chord) so callers can keep their on/off UI truthful.
    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }
        guard let t = HotKeyCenter.shared.register(
            keyCode: Self.spec.keyCode,
            modifiers: Self.spec.modifiers,
            action: {
                GlobalHotKeyService.pressSerial &+= 1
                NotificationCenter.default.post(
                    name: GlobalHotKeyService.toggleNotification,
                    object: NSNumber(value: GlobalHotKeyService.pressSerial))
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

    func keyDown(_ hidCode: Int, chord: [Int]? = nil, owner: String = "", repeats: Bool = false) {}
    func keyUp(_ hidCode: Int, owner: String = "") {}
    func mouseButtonDown(_ button: Int, owner: String = "", singleClick: Bool = false) {}
    func mouseButtonUp(_ button: Int, owner: String = "") {}
    func moveMouse(deltaX: Int, deltaY: Int) {}
    func scrollWheel(deltaX: Int32, deltaY: Int32) {}
    func scrollWheelStep(axis: MouseAxis, direction: MouseDirection, lines: Int = 1) {}
    func releaseAll() {}
    func releaseOwners(withPrefix prefix: String) {}
    func ownDeviceModifierBits() -> UInt { 0 }

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
                // Only on a change: each publish redraws every chooser.
                if cache.shortcuts != shortcuts { cache.shortcuts = shortcuts }
                if cache.apps != apps { cache.apps = apps }
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
            openLaunchpad()
        case .spotlight:
            postCombo(keyCode: 49, flags: .maskCommand)            // Cmd+Space
        case .lockScreen:
            // Ctrl+Cmd+Q, where Q is wherever the current layout puts it
            // (the A key on AZERTY); macOS matches the shortcut by letter.
            postCombo(keyCode: CGKeyCode(Self.virtualKey(typing: "q", command: true) ?? 12), flags: [.maskControl, .maskCommand])
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

    /// The virtual key that types `character` on the current keyboard
    /// layout, or nil when the layout has no unmodified key for it.
    /// With `command`, the key that types it while Command is held, which
    /// is what a shortcut matches: "Dvorak - QWERTY Command" types Dvorak
    /// letters plain and QWERTY ones with Command, so the plain search sent
    /// Control Command X for Lock Screen. Falls back to the plain search.
    static func virtualKey(typing character: Character, command: Bool) -> Int? {
        if command, let code = virtualKey(typing: character, modifierState: UInt32((cmdKey >> 8) & 0xFF)) { return code }
        return virtualKey(typing: character)
    }

    static func virtualKey(typing character: Character) -> Int? {
        virtualKey(typing: character, modifierState: 0)
    }

    /// What a key types on the current layout with no modifiers, or nil.
    static func character(forVirtualKey code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length)
            return s.trimmingCharacters(in: .controlCharacters).isEmpty ? nil : s
        }
    }

    private static func virtualKey(typing character: Character, modifierState: UInt32) -> Int? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        return data.withUnsafeBytes { buffer -> Int? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifierState,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0,
                   String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return code
                }
            }
            return nil
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
                InputSimulator.notePost(cg.type)
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
            InputSimulator.notePost(event.type)
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
            InputSimulator.notePost(event.type)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Mac shortcuts

    /// Launchpad, or Apps on macOS 26 and later, where Launchpad.app is
    /// gone. Found by bundle id so the path does not matter; a miss is
    /// logged rather than silent.
    private func openLaunchpad() {
        let ids = ["com.apple.apps.launcher", "com.apple.launchpad.launcher"]
        guard let url = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            ActivityLog.shared.warning("Outputs", "Could not find Launchpad or Apps on this Mac")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

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
            let errors = Pipe()
            task.standardError = errors
            do {
                try task.run()
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                task.waitUntilExit()
                if task.terminationStatus == 0 { return }
                // Fall back only when the tool could not reach Shortcuts. Not
                // judged from its error text, which is localized and varies:
                // if the tool can list this shortcut it reached Shortcuts,
                // so the shortcut ran and failed partway, and running it
                // again through the URL scheme would run it twice.
                if self.installedShortcuts().contains(name) {
                    let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    ActivityLog.shared.warning("Outputs", "Shortcut \u{201C}\(name)\u{201D} did not finish" + (detail.isEmpty ? "" : ": \(detail)"))
                    return
                }
                NSLog("[SystemAction] shortcuts run '%@' could not reach Shortcuts; falling back to URL scheme", name)
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
        var names = Set<String>(Self.appBundlesByName().keys)
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

    /// The folders apps live in. The user's own Applications folder is
    /// found through the account's real home: NSHomeDirectory() is the
    /// sandbox container, where no apps are.
    private static var appDirectories: [String] {
        var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            dirs.append(String(cString: home) + "/Applications")
        }
        return dirs
    }

    nonisolated(unsafe) private static var appBundleCache: (at: Date, map: [String: URL])?
    private static func cachedAppBundlesByName() -> [String: URL] {
        if let cache = appBundleCache, Date().timeIntervalSince(cache.at) < 60 { return cache.map }
        let map = appBundlesByName()
        appBundleCache = (Date(), map)
        return map
    }

    /// Every app bundle in those folders and one folder deeper (apps that
    /// install into a vendor folder), by name.
    private static func appBundlesByName() -> [String: URL] {
        var out: [String: URL] = [:]
        let fm = FileManager.default
        for dir in appDirectories {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let path = dir + "/" + item
                if item.hasSuffix(".app") {
                    let name = String(item.dropLast(4))
                    if out[name] == nil { out[name] = URL(fileURLWithPath: path) }
                } else if let inner = try? fm.contentsOfDirectory(atPath: path) {
                    for sub in inner where sub.hasSuffix(".app") {
                        let name = String(sub.dropLast(4))
                        if out[name] == nil { out[name] = URL(fileURLWithPath: path + "/" + sub) }
                    }
                }
            }
        }
        return out
    }

    private func openApp(_ target: String) {
        let config = NSWorkspace.OpenConfiguration()
        let url: URL? = {
            if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
            // The usual places first, one file check each, as 1.5 did; the
            // full folder scan runs on every press on the main thread, so it
            // is the fallback, and its result is kept for a minute.
            for dir in Self.appDirectories {
                let path = dir + "/" + target + ".app"
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
            if let found = Self.cachedAppBundlesByName()[target] { return found }
            // A running app listed by its display name, which can differ
            // from its bundle's file name.
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == target }),
               let bundle = running.bundleURL { return bundle }
            // Last try: the string as a bundle identifier.
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
        }()
        guard let url else {
            ActivityLog.shared.warning("Outputs", "Open App could not find \u{201C}\(target)\u{201D}")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
