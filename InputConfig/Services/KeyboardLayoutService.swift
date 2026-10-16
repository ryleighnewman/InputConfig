import Foundation
import Carbon.HIToolbox
import Combine

/// The keyboard as the person in front of the Mac has it: its physical shape
/// (ANSI, ISO or JIS) and the character each key types under their input
/// source (QWERTZ, AZERTY, Dvorak, Russian, Arabic and every other layout
/// macOS ships). Keys are stored by position everywhere in the app (HID
/// usages, layout independent), so this changes only what a key is called
/// and drawn as, never what a row matches or sends.
///
/// The characters come from the layout's own `uchr` data through
/// `UCKeyTranslate`, the same data Keyboard Viewer draws from, so a layout
/// added in a later macOS works without a table here.
@MainActor
final class KeyboardLayoutService: ObservableObject {
    static let shared = KeyboardLayoutService()

    /// The physical arrangement of the main block.
    enum Shape: String, CaseIterable, Identifiable {
        /// US and most of the Americas and Asia: a wide Return, a long left Shift.
        case ansi
        /// Most of Europe: a tall Return, a key left of Z and one top left.
        case iso
        /// Japan: a tall Return, the Yen and underscore keys, Eisu and Kana by the space bar.
        case jis
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ansi: return String(localized: "ANSI (US)")
            case .iso: return String(localized: "ISO (Europe)")
            case .jis: return String(localized: "JIS (Japan)")
            }
        }
    }

    /// When the keyboard map shows the navigation keys and number pad.
    enum ExtendedKeys: String, CaseIterable, Identifiable {
        /// When a row uses one of those keys, or a keyboard that has them is connected.
        case automatic
        case always
        case never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return String(localized: "Automatic")
            case .always: return String(localized: "Always")
            case .never: return String(localized: "Never")
            }
        }
    }

    /// One keyboard layout macOS has installed, for the labels picker.
    struct LayoutChoice: Identifiable, Hashable {
        let id: String      // TIS input source ID, e.g. com.apple.keylayout.French
        let name: String    // localized by macOS
    }

    // MARK: Settings (new keys, nothing renamed)

    static let shapeKey = "InputConfig.keyboardShape"            // "automatic" or a Shape
    static let labelSourceKey = "InputConfig.keyboardLabelSource" // "" follows the input source
    static let extendedKey = "InputConfig.keyboardExtendedKeys"   // an ExtendedKeys

    /// nil follows the keyboard macOS reports; a value forces that shape.
    @Published var shapeOverride: Shape? {
        didSet {
            UserDefaults.standard.set(shapeOverride?.rawValue ?? "automatic", forKey: Self.shapeKey)
            KeyLabelCache.isJIS = shape == .jis
        }
    }
    /// Empty follows the current input source; otherwise a TIS input source ID.
    @Published var labelSourceID: String {
        didSet {
            UserDefaults.standard.set(labelSourceID, forKey: Self.labelSourceKey)
            reload()
        }
    }
    @Published var extendedKeys: ExtendedKeys {
        didSet { UserDefaults.standard.set(extendedKeys.rawValue, forKey: Self.extendedKey) }
    }

    // MARK: State

    /// The shape macOS reports for the keyboard typed on last.
    @Published private(set) var detectedShape: Shape = .ansi
    /// Virtual key code to the label drawn on that key.
    @Published private(set) var labels: [Int: String] = [:]
    /// The name of the layout the labels come from, as macOS shows it.
    @Published private(set) var sourceName: String = ""

    /// The shape the map draws.
    var shape: Shape { shapeOverride ?? detectedShape }

    private var observers: [NSObjectProtocol] = []

    private init() {
        let d = UserDefaults.standard
        shapeOverride = Shape(rawValue: d.string(forKey: Self.shapeKey) ?? "")
        labelSourceID = Self.installedOrFollow(d.string(forKey: Self.labelSourceKey) ?? "")
        extendedKeys = ExtendedKeys(rawValue: d.string(forKey: Self.extendedKey) ?? "") ?? .automatic
        reload()
        // A new input source picked from the menu bar, or a different
        // keyboard typed on, changes the labels and maybe the shape.
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(dnc.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
    }

    /// The keyboard type last read. A key from a keyboard of another kind
    /// (an ISO Magic Keyboard on an ANSI MacBook) changes it without any
    /// input source notification, so the key handler asks here.
    nonisolated(unsafe) private static var lastKeyboardType = LMGetKbdType()

    /// Called for each key event; cheap when nothing changed.
    nonisolated static func noteKeyEvent() {
        let now = LMGetKbdType()
        guard now != lastKeyboardType else { return }
        lastKeyboardType = now
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.reload() } }
    }

    /// Reads the three settings again after Reset Settings or a restored
    /// backup changed them behind the menu's back.
    func reloadFromDefaults() {
        let d = UserDefaults.standard
        let shape = Shape(rawValue: d.string(forKey: Self.shapeKey) ?? "")
        let source = Self.installedOrFollow(d.string(forKey: Self.labelSourceKey) ?? "")
        let extended = ExtendedKeys(rawValue: d.string(forKey: Self.extendedKey) ?? "") ?? .automatic
        if shapeOverride != shape { shapeOverride = shape }
        if labelSourceID != source { labelSourceID = source }
        if extendedKeys != extended { extendedKeys = extended }
    }

    /// A layout picked on another Mac (a restored backup) that this Mac
    /// does not have follows the input source instead, so the menu checks
    /// what the labels really show.
    private static func installedOrFollow(_ id: String) -> String {
        id.isEmpty || inputSource(id: id) != nil ? id : ""
    }

    /// Reads the shape and the labels again.
    func reload() {
        Self.lastKeyboardType = LMGetKbdType()
        // Which characters the layout can type may have changed too.
        KeyLabelCache.forgetTypable()
        let shape = Self.currentShape()
        let source: TISInputSource? = labelSourceID.isEmpty
            ? Self.currentLayoutSource()
            : Self.inputSource(id: labelSourceID) ?? Self.currentLayoutSource()
        let name = source.flatMap { Self.string($0, kTISPropertyLocalizedName) } ?? ""
        let table = source.map(Self.labels(for:)) ?? [:]
        // Only real changes are published: an input method switching modes
        // (Kana and Eisu, 한/영) posts the notification with the layout
        // unchanged, and every published write redraws the open editor.
        if detectedShape != shape { detectedShape = shape }
        KeyLabelCache.isJIS = (shapeOverride ?? shape) == .jis
        if sourceName != name { sourceName = name }
        if labels != table { labels = table; KeyLabelCache.store(table) }
    }

    /// Every keyboard layout installed, enabled or not, sorted by name.
    func installedLayouts() -> [LayoutChoice] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        var seen = Set<String>()
        return list.compactMap { s -> LayoutChoice? in
            guard let id = Self.string(s, kTISPropertyInputSourceID), let name = Self.string(s, kTISPropertyLocalizedName),
                  seen.insert(id).inserted else { return nil }
            return LayoutChoice(id: id, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: macOS lookups

    nonisolated static func currentShape() -> Shape {
        switch Int(KBGetLayoutType(Int16(LMGetKbdType()))) {
        case Int(kKeyboardISO): return .iso
        case Int(kKeyboardJIS): return .jis
        default: return .ansi
        }
    }

    /// The layout the keys are labeled from when following the input
    /// source. An input method's own hidden layout (Korean 2-Set's jamo
    /// while in 한 mode) gives way to the Latin layout printed on the same
    /// keycaps, so names do not flip on every 한/영 press; a plain layout
    /// that is not Latin (Russian, Greek) keeps its own letters.
    nonisolated static func currentLayoutSource() -> TISInputSource? {
        guard let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let isInputMode = current.flatMap { string($0, kTISPropertyInputSourceType) } == (kTISTypeKeyboardInputMode as String)
        if isInputMode, !bool(layout, kTISPropertyInputSourceIsASCIICapable),
           let latin = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            return latin
        }
        return layout
    }

    nonisolated static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    nonisolated static func inputSource(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    nonisolated static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// The virtual key codes that type a character, the ones worth asking the layout about.
    nonisolated static let printableKeys: [Int] =
        Array(0...50).filter { ![36, 48, 49].contains($0) }   // letters, numbers, punctuation; not Return, Tab, Space
        + [93, 94, 95]                                         // Yen, underscore, keypad comma (JIS)

    /// The label each printable key shows under one layout: what it types,
    /// as printed on a keycap (letters in capitals, a digit when Shift
    /// gives one and the plain key gives a symbol, as on AZERTY).
    nonisolated static func labels(for source: TISInputSource) -> [Int: String] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let kbd = UInt32(LMGetKbdType())
        let language = (TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
            .map { Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as? [String] } ?? nil)?.first
        let locale = language.map(Locale.init(identifier:))
        var out: [Int: String] = [:]
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            func type(_ vk: Int, shift: Bool) -> String? {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 8)
                var length = 0
                let mods: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
                let status = UCKeyTranslate(base, UInt16(vk), UInt16(kUCKeyActionDisplay), mods, kbd,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                // Invisible marks (Hebrew and Arabic layouts type direction
                // marks on some keys) leave nothing to draw: dropped only when
                // nothing else is left, so a joiner that tells two Sinhala
                // keys apart stays.
                let raw = String(utf16CodeUnits: chars, count: length)
                let visible = String(String.UnicodeScalarView(raw.unicodeScalars
                    .filter { $0.properties.generalCategory != .format && $0.properties.generalCategory != .control }))
                var s = visible.isEmpty ? visible : raw.trimmingCharacters(in: .controlCharacters)
                if s.unicodeScalars.first.map({ $0.properties.generalCategory == .format }) == true { s = visible }
                // A vowel sign or other combining mark alone is drawn on a
                // dotted circle, as keycaps and Keyboard Viewer show it.
                if let first = s.unicodeScalars.first,
                   [.nonspacingMark, .spacingMark, .enclosingMark].contains(first.properties.generalCategory) {
                    s = "\u{25CC}" + s
                }
                // Control characters and bare spacing marks are not labels.
                guard let scalar = s.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F,
                      !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return s
            }
            // The digit each number-row key carries on a keycap.
            let rowDigit: [Int: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0]
            for vk in printableKeys {
                guard let plain = type(vk, shift: false) else { continue }
                var label = plain
                if let shifted = type(vk, shift: true), shifted.count == 1, shifted.first?.isNumber == true,
                   plain.first?.isNumber != true, shifted.first?.wholeNumberValue == rowDigit[vk] {
                    // The number row on AZERTY and Czech types a symbol or an
                    // accented letter and the digit with Shift; the keycap
                    // reads as the digit.
                    label = shifted
                } else if plain.count == 1, let c = plain.first, c.isLetter {
                    // A capital where the keycap prints one: the capital the
                    // key types with Shift, in the layout's own language
                    // (Turkish i is İ). ß stays ß, not SS, and Greek ς stays
                    // ς rather than repeating the Σ of the S key.
                    let upper = plain.uppercased(with: locale)
                    let shifted = type(vk, shift: true)
                    if let shifted, shifted.count == 1, shifted == plain.uppercased() {
                        // Shift types the plain capital (Turkish Q Legacy's I).
                        label = shifted
                    } else if upper.count == 1, upper == shifted {
                        label = upper
                    } else if let shifted, shifted.count == 1, let c = shifted.first, c.isLetter, c.isUppercase {
                        // Shift types another capital (Macedonian ѕ and S).
                        label = upper.count == 1 ? upper : shifted
                    }
                }
                out[vk] = label
            }
        }
        return out
    }
}

/// The current labels, readable from any thread (key names are built off
/// the main actor too, for row summaries and VoiceOver).
enum KeyLabelCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [Int: String] = [:]

    nonisolated(unsafe) private static var jis = false
    nonisolated(unsafe) private static var typableCache: [String: Bool] = [:]

    /// Whether the current layout has a key for a character, worked out
    /// once per layout (output names ask on every redraw).
    static func typable(_ c: Character, command: Bool, compute: () -> Bool) -> Bool {
        let key = (command ? "c" : "p") + String(c)
        lock.lock()
        if let known = typableCache[key] { lock.unlock(); return known }
        lock.unlock()
        let value = compute()
        lock.lock(); typableCache[key] = value; lock.unlock()
        return value
    }

    static func forgetTypable() { lock.lock(); typableCache.removeAll(); lock.unlock() }

    static func store(_ t: [Int: String]) { lock.lock(); table = t; lock.unlock() }

    /// Whether the map draws a JIS keyboard, readable from any thread.
    static var isJIS: Bool {
        get { lock.lock(); defer { lock.unlock() }; return jis }
        set { lock.lock(); jis = newValue; lock.unlock() }
    }

    /// The label for a virtual key code, or nil when the layout has none.
    static func label(forVirtualKey vk: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return table[vk]
    }
}
