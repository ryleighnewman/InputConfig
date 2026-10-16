import Foundation

/// Maps HID usage codes to human-readable key names
/// Based on the original Joystick Mapper's key code table
struct KeyCodeMap {
    /// fn HELD as a modifier. macOS exposes this as an event flag rather than
    /// a keyboard usage, so it gets a private code well clear of the HID
    /// keyboard page (which tops out in the 200s here). Measured: holding the
    /// key raises `flagsChanged vk=63` and stamps `.maskSecondaryFn` on
    /// whichever key is pressed alongside it.
    static let globeFnCode = 400

    /// The Globe key TAPPED on its own, which is a different event from
    /// holding fn: macOS emits a discrete `keyDown vk=179` carrying no fn
    /// flag, and that is what fires the "Press the Globe key to" action
    /// (emoji picker, input source, dictation). Holding fn as a modifier
    /// never produces it.
    static let globeKeyCode = 401
    /// Virtual keycode the Globe tap reports as. Measured, not inferred.
    static let globeVirtualKey = 179

    /// The MacBook top-row keys that arrive as ordinary key events with
    /// virtual keycodes of their own rather than as media keys: Spotlight
    /// (vk 177), Dictation (vk 176), and Focus / Do Not Disturb (vk 178).
    /// Mission Control (vk 160) and Launchpad (vk 131) reuse the codes the
    /// output side already has for them, 304 and 303.
    static let spotlightKeyCode = 314
    static let dictationKeyCode = 315
    static let focusKeyCode = 316

    /// A key the tables have no entry for still reaches a binding: its macOS
    /// virtual key code is stored above this base and shows as "Key code N".
    /// Well clear of the HID keyboard page and the private codes above it.
    static let unknownKeyBase = 2000
    /// The same for a media-style (system-defined) key with an unfamiliar
    /// key type: stored above this base, shown as "Special key N".
    static let unknownSystemKeyBase = 3000

    struct KeyEntry: Identifiable {
        let id: Int
        let code: Int
        let name: String
        let group: String

        init(code: Int, name: String, group: String) {
            self.id = code
            self.code = code
            self.name = name
            self.group = group
        }
    }

    static let allKeys: [KeyEntry] = {
        var keys: [KeyEntry] = []
        // Section names are shown in the key menus; entries stay grouped by the same string.
        let groupLetterKeys = String(localized: "Letter Keys")
        let groupNumberKeys = String(localized: "Number Keys")
        let groupOtherCharacters = String(localized: "Other Characters")
        let groupArrowKeys = String(localized: "Arrow Keys")
        let groupModifierKeys = String(localized: "Modifier Keys")
        let groupOtherKeys = String(localized: "Other Keys")
        let groupFunctionKeys = String(localized: "Function Keys")
        let groupKeypadKeys = String(localized: "Keypad Keys")
        let groupInternationalKeys = String(localized: "International Keys")
        let groupSpecialKeys = String(localized: "Special Keys")

        // Letter Keys
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for (i, char) in letters.enumerated() {
            keys.append(KeyEntry(code: 4 + i, name: String(char), group: groupLetterKeys))
        }

        // Number Keys
        for i in 1...9 {
            keys.append(KeyEntry(code: 29 + i, name: "\(i)", group: groupNumberKeys))
        }
        keys.append(KeyEntry(code: 39, name: "0", group: groupNumberKeys))

        // Other Characters
        keys.append(contentsOf: [
            KeyEntry(code: 45, name: "-", group: groupOtherCharacters),
            KeyEntry(code: 46, name: "=", group: groupOtherCharacters),
            KeyEntry(code: 47, name: "[", group: groupOtherCharacters),
            KeyEntry(code: 48, name: "]", group: groupOtherCharacters),
            KeyEntry(code: 49, name: "\\", group: groupOtherCharacters),
            KeyEntry(code: 50, name: "# ~ (ISO, next to Return)", group: groupOtherCharacters),
            KeyEntry(code: 51, name: ";", group: groupOtherCharacters),
            KeyEntry(code: 52, name: "'", group: groupOtherCharacters),
            KeyEntry(code: 53, name: "`", group: groupOtherCharacters),
            KeyEntry(code: 54, name: ",", group: groupOtherCharacters),
            KeyEntry(code: 55, name: ".", group: groupOtherCharacters),
            KeyEntry(code: 56, name: "/", group: groupOtherCharacters),
        ])

        // Arrow Keys
        keys.append(contentsOf: [
            KeyEntry(code: 79, name: "Right", group: groupArrowKeys),
            KeyEntry(code: 80, name: "Left", group: groupArrowKeys),
            KeyEntry(code: 81, name: "Down", group: groupArrowKeys),
            KeyEntry(code: 82, name: "Up", group: groupArrowKeys),
        ])

        // Modifier Keys
        keys.append(contentsOf: [
            KeyEntry(code: 227, name: "Command (Left)", group: groupModifierKeys),
            KeyEntry(code: 231, name: "Command (Right)", group: groupModifierKeys),
            KeyEntry(code: 225, name: "Shift (Left)", group: groupModifierKeys),
            KeyEntry(code: 229, name: "Shift (Right)", group: groupModifierKeys),
            KeyEntry(code: 226, name: "Alt / Option (Left)", group: groupModifierKeys),
            KeyEntry(code: 230, name: "Alt / Option (Right)", group: groupModifierKeys),
            KeyEntry(code: 224, name: "Ctrl (Left)", group: groupModifierKeys),
            KeyEntry(code: 228, name: "Ctrl (Right)", group: groupModifierKeys),
            KeyEntry(code: KeyCodeMap.globeFnCode, name: "fn / Globe (hold)", group: groupModifierKeys),
        ])

        // Other Keys
        keys.append(contentsOf: [
            KeyEntry(code: 44, name: "Space", group: groupOtherKeys),
            KeyEntry(code: 40, name: "Return", group: groupOtherKeys),
            KeyEntry(code: 41, name: "Escape", group: groupOtherKeys),
            KeyEntry(code: 42, name: "Backspace", group: groupOtherKeys),
            KeyEntry(code: 43, name: "Tab", group: groupOtherKeys),
            KeyEntry(code: 73, name: "Insert", group: groupOtherKeys),
            KeyEntry(code: 74, name: "Home", group: groupOtherKeys),
            KeyEntry(code: 75, name: "PageUp", group: groupOtherKeys),
            KeyEntry(code: 76, name: "Delete", group: groupOtherKeys),
            KeyEntry(code: 77, name: "End", group: groupOtherKeys),
            KeyEntry(code: 78, name: "PageDown", group: groupOtherKeys),
            KeyEntry(code: 57, name: "Caps Lock", group: groupOtherKeys),
            KeyEntry(code: 70, name: "PrintScreen (F13)", group: groupOtherKeys),
            KeyEntry(code: 101, name: "Application", group: groupOtherKeys),
        ])

        // Function Keys
        for i in 1...12 {
            keys.append(KeyEntry(code: 57 + i, name: "F\(i)", group: groupFunctionKeys))
        }
        // F21 to F24 have no macOS key code, so they are left out of the
        // pickers; see `unavailableKeys` for presets that stored them.
        for i in 13...20 {
            keys.append(KeyEntry(code: 91 + i, name: "F\(i)", group: groupFunctionKeys))
        }

        // Keypad Keys
        keys.append(contentsOf: [
            KeyEntry(code: 83, name: "Numlock", group: groupKeypadKeys),
            KeyEntry(code: 84, name: "Keypad /", group: groupKeypadKeys),
            KeyEntry(code: 85, name: "Keypad *", group: groupKeypadKeys),
            KeyEntry(code: 86, name: "Keypad -", group: groupKeypadKeys),
            KeyEntry(code: 87, name: "Keypad +", group: groupKeypadKeys),
            KeyEntry(code: 88, name: "Keypad Enter", group: groupKeypadKeys),
            KeyEntry(code: 89, name: "Keypad 1", group: groupKeypadKeys),
            KeyEntry(code: 90, name: "Keypad 2", group: groupKeypadKeys),
            KeyEntry(code: 91, name: "Keypad 3", group: groupKeypadKeys),
            KeyEntry(code: 92, name: "Keypad 4", group: groupKeypadKeys),
            KeyEntry(code: 93, name: "Keypad 5", group: groupKeypadKeys),
            KeyEntry(code: 94, name: "Keypad 6", group: groupKeypadKeys),
            KeyEntry(code: 95, name: "Keypad 7", group: groupKeypadKeys),
            KeyEntry(code: 96, name: "Keypad 8", group: groupKeypadKeys),
            KeyEntry(code: 97, name: "Keypad 9", group: groupKeypadKeys),
            KeyEntry(code: 98, name: "Keypad 0", group: groupKeypadKeys),
            KeyEntry(code: 99, name: "Keypad .", group: groupKeypadKeys),
            KeyEntry(code: 103, name: "Keypad =", group: groupKeypadKeys),
            KeyEntry(code: 133, name: "Keypad ,", group: groupKeypadKeys),
        ])

        // ISO and Japanese keyboard keys. Without these they scanned as
        // nothing at all.
        keys.append(contentsOf: [
            KeyEntry(code: 100, name: "\u{00A7} (ISO)", group: groupInternationalKeys),
            KeyEntry(code: 137, name: "Yen (JIS)", group: groupInternationalKeys),
            KeyEntry(code: 135, name: "Underscore (JIS)", group: groupInternationalKeys),
            KeyEntry(code: 145, name: "Eisu (JIS)", group: groupInternationalKeys),
            KeyEntry(code: 144, name: "Kana (JIS)", group: groupInternationalKeys),
        ])

        // Special / Media Keys
        keys.append(contentsOf: [
            KeyEntry(code: 71, name: "Brightness Down", group: groupSpecialKeys),
            KeyEntry(code: 72, name: "Brightness Up", group: groupSpecialKeys),
            KeyEntry(code: 303, name: "Dashboard/Launchpad", group: groupSpecialKeys),
            KeyEntry(code: 304, name: "Mission Control", group: groupSpecialKeys),
            KeyEntry(code: 305, name: "Keyboard Light Down", group: groupSpecialKeys),
            KeyEntry(code: 306, name: "Keyboard Light Up", group: groupSpecialKeys),
            KeyEntry(code: KeyCodeMap.globeKeyCode, name: "Globe Key (Emoji)", group: groupSpecialKeys),
            KeyEntry(code: 307, name: "Previous Track / Rewind", group: groupSpecialKeys),
            KeyEntry(code: 308, name: "Play / Pause", group: groupSpecialKeys),
            KeyEntry(code: 309, name: "Next Track / Fast Forward", group: groupSpecialKeys),
            KeyEntry(code: 310, name: "Mute Sound", group: groupSpecialKeys),
            KeyEntry(code: 311, name: "Volume Up", group: groupSpecialKeys),
            KeyEntry(code: 312, name: "Volume Down", group: groupSpecialKeys),
            KeyEntry(code: 313, name: "Eject", group: groupSpecialKeys),
            KeyEntry(code: KeyCodeMap.spotlightKeyCode, name: "Spotlight Key", group: groupSpecialKeys),
            KeyEntry(code: KeyCodeMap.dictationKeyCode, name: "Dictation Key", group: groupSpecialKeys),
            KeyEntry(code: KeyCodeMap.focusKeyCode, name: "Focus / Do Not Disturb Key", group: groupSpecialKeys),
        ])

        return keys
    }()

    /// All unique group names in order
    static let groups: [String] = {
        var seen = Set<String>()
        var result: [String] = []
        for key in allKeys {
            if !seen.contains(key.group) {
                seen.insert(key.group)
                result.append(key.group)
            }
        }
        return result
    }()

    /// Keys grouped by category
    static let keysByGroup: [String: [KeyEntry]] = {
        Dictionary(grouping: allKeys, by: { $0.group })
    }()

    /// Keys an older version offered that macOS cannot send (F21 to F24).
    /// Kept out of every picker, but still named so a preset that stored
    /// one shows what it is instead of a bare number.
    static let unavailableKeys: [KeyEntry] = (21...24).map {
        KeyEntry(code: 91 + $0, name: String(localized: "F\($0) (not available on Mac)"), group: String(localized: "Function Keys"))
    }

    private static let codeToName: [Int: String] = {
        Dictionary(uniqueKeysWithValues: (allKeys + unavailableKeys).map { ($0.code, $0.name) })
    }()

    /// What a key is called. A key that types a character is named for what
    /// it types under the person's keyboard layout (the key US keyboards call
    /// A is Q on AZERTY and Ф on Russian), so menus and summaries match the
    /// keycaps in front of them; every other key keeps its own name. Rows
    /// store the key's position, so this never changes what a row does.
    static func name(for code: Int) -> String {
        // The ISO key by Return and the JIS keypad comma share a key code with
        // backslash and comma, so they keep names of their own.
        // The JIS Yen and underscore keys too, unless the keyboard is JIS:
        // another layout's characters on them ("^" and "<" on German)
        // repeat its own keys' names in the menus.
        let jisOnly: Set<Int> = [135, 137]
        if code != 50, code != 133, !jisOnly.contains(code) || KeyLabelCache.isJIS,
           let vk = hidToVirtualKeyCode[code], printableVirtualKeys.contains(vk),
           let label = KeyLabelCache.label(forVirtualKey: vk) {
            // A label the table's own name starts with keeps the fuller
            // name: "§ (ISO)" on a US layout says the key is ISO only.
            if let base = codeToName[code], base != label, base.hasPrefix(label + " ") {
                return String(localized: String.LocalizationValue(base), table: "KeyNames")
            }
            return label
        }
        // The rest by their names in the app's language (Escape, Keypad 1, Mission
        // Control); the English names stay the table's keys.
        // From a table of their own, KeyNames, so the Home key never takes
        // the translation of a controller's Home button.
        if let name = codeToName[code] { return String(localized: String.LocalizationValue(name), table: "KeyNames") }
        if code >= unknownSystemKeyBase { return String(localized: "Special key \(code - unknownSystemKeyBase)") }
        if code >= unknownKeyBase { return String(localized: "Key code \(code - unknownKeyBase)") }
        return String(localized: "Key \(code)")
    }

    /// The keys `name(for:)` asks the layout about.
    private static let printableVirtualKeys = Set(KeyboardLayoutService.printableKeys)

    /// The English name a key has on a US keyboard, whatever the layout.
    /// Command and Control, left and right: in a chord with one of them a
    /// key is sent as a shortcut (InputSimulator.virtualCode).
    static let shortcutModifierCodes: Set<Int> = [224, 227, 228, 231]

    /// Whether a key output is sent as the character it types on a US
    /// keyboard rather than by its position: letters and punctuation in a
    /// Command or Control shortcut (macOS matches shortcuts by character,
    /// so Undo is Command Z on every layout), and with Keys follow the
    /// keyboard layout on, plain letters, digits and punctuation too.
    static func sendsUSCharacter(_ code: Int, inShortcut: Bool) -> Bool {
        let letterOrMark = (4...29).contains(code) || [45, 46, 47, 48, 49, 51, 52, 54, 55, 56].contains(code)
        if inShortcut { return letterOrMark }
        return (letterOrMark || (30...39).contains(code))
            && UserDefaults.standard.bool(forKey: InputSimulator.followLayoutKey)
    }

    /// A key's name as an output: what pressing it will do. A key sent by
    /// its character is named by that character ("Z" in Command Z on a
    /// German keyboard); a key sent by position by its keycap, like inputs.
    static func outputName(for code: Int, inShortcut: Bool) -> String {
        sendsUSCharacter(code, inShortcut: inShortcut) && InputSimulator.sendsByCharacter(code, inShortcut: inShortcut)
            ? (codeToName[code] ?? name(for: code)) : name(for: code)
    }

    static func usName(for code: Int) -> String {
        codeToName[code] ?? name(for: code)
    }

    static func code(for name: String) -> Int? {
        allKeys.first(where: { $0.name == name })?.code
    }

    /// HID usage code to macOS virtual key code mapping (for CGEvent)
    /// This maps the HID codes used in presets to the macOS virtual key codes needed for CGEvent
    static let hidToVirtualKeyCode: [Int: Int] = [
        // Launchpad and Mission Control keys: virtual codes of their own
        // (the same ones the MacBook top row sends), not media key types.
        303: 131, 304: 160,
        spotlightKeyCode: 177, dictationKeyCode: 176, focusKeyCode: 178,
        4: 0x00,   // A
        5: 0x0B,   // B
        6: 0x08,   // C
        7: 0x02,   // D
        8: 0x0E,   // E
        9: 0x03,   // F
        10: 0x05,  // G
        11: 0x04,  // H
        12: 0x22,  // I
        13: 0x26,  // J
        14: 0x28,  // K
        15: 0x25,  // L
        16: 0x2E,  // M
        17: 0x2D,  // N
        18: 0x1F,  // O
        19: 0x23,  // P
        20: 0x0C,  // Q
        21: 0x0F,  // R
        22: 0x01,  // S
        23: 0x11,  // T
        24: 0x20,  // U
        25: 0x09,  // V
        26: 0x0D,  // W
        27: 0x07,  // X
        28: 0x10,  // Y
        29: 0x06,  // Z
        30: 0x12,  // 1
        31: 0x13,  // 2
        32: 0x14,  // 3
        33: 0x15,  // 4
        34: 0x17,  // 5
        35: 0x16,  // 6
        36: 0x1A,  // 7
        37: 0x1C,  // 8
        38: 0x19,  // 9
        39: 0x1D,  // 0
        40: 0x24,  // Return
        41: 0x35,  // Escape
        42: 0x33,  // Backspace
        43: 0x30,  // Tab
        44: 0x31,  // Space
        45: 0x1B,  // -
        46: 0x18,  // =
        47: 0x21,  // [
        48: 0x1E,  // ]
        49: 0x2A,  // backslash
        50: 0x2A,  // the ISO key next to Return (# ~), which macOS reads as backslash's key
        51: 0x29,  // ;
        52: 0x27,  // '
        53: 0x32,  // `
        54: 0x2B,  // ,
        55: 0x2F,  // .
        56: 0x2C,  // /
        57: 0x39,  // Caps Lock
        58: 0x7A,  // F1
        59: 0x78,  // F2
        60: 0x63,  // F3
        61: 0x76,  // F4
        62: 0x60,  // F5
        63: 0x61,  // F6
        64: 0x62,  // F7
        65: 0x64,  // F8
        66: 0x65,  // F9
        67: 0x6D,  // F10
        68: 0x67,  // F11
        69: 0x6F,  // F12
        104: 0x69, // F13
        70: 0x69,  // PrintScreen: a PC keyboard's Print Screen is F13 on a Mac
        105: 0x6B, // F14
        106: 0x71, // F15
        107: 0x6A, // F16
        108: 0x40, // F17
        109: 0x4F, // F18
        110: 0x50, // F19
        111: 0x5A, // F20
        74: 0x73,  // Home
        75: 0x74,  // PageUp
        76: 0x75,  // Delete (forward)
        77: 0x77,  // End
        78: 0x79,  // PageDown
        79: 0x7C,  // Right
        80: 0x7B,  // Left
        81: 0x7D,  // Down
        82: 0x7E,  // Up
        73: 0x72,  // Insert (the Help key, its position on a Mac keyboard)
        83: 0x47,  // Keypad Clear (Num Lock position on Mac)
        84: 0x4B,  // Keypad /
        85: 0x43,  // Keypad *
        86: 0x4E,  // Keypad -
        87: 0x45,  // Keypad +
        88: 0x4C,  // Keypad Enter
        89: 0x53,  // Keypad 1
        90: 0x54,  // Keypad 2
        91: 0x55,  // Keypad 3
        92: 0x56,  // Keypad 4
        93: 0x57,  // Keypad 5
        94: 0x58,  // Keypad 6
        95: 0x59,  // Keypad 7
        96: 0x5B,  // Keypad 8
        97: 0x5C,  // Keypad 9
        98: 0x52,  // Keypad 0
        99: 0x41,  // Keypad .
        103: 0x51, // Keypad =
        133: 0x5F, // Keypad , (JIS)
        101: 0x6E, // Application / Menu (PC keyboards)
        100: 0x0A, // Section (ISO)
        137: 0x5D, // Yen (JIS)
        135: 0x5E, // Underscore (JIS)
        145: 0x66, // Eisu (JIS)
        144: 0x68, // Kana (JIS)
        KeyCodeMap.globeKeyCode: KeyCodeMap.globeVirtualKey, // Globe tapped alone
        224: 0x3B, // Ctrl Left
        225: 0x38, // Shift Left
        226: 0x3A, // Option Left
        227: 0x37, // Command Left
        228: 0x3E, // Ctrl Right
        229: 0x3C, // Shift Right
        230: 0x3D, // Option Right
        231: 0x36, // Command Right
    ]
}
