import Foundation

/// How a screen text row fires.
enum ScreenTextMode: String, Codable, CaseIterable, Identifiable {
    /// Held, like a button, while the text is read inside the area.
    case shows
    /// A short press when the text appears in the area after not being there.
    case appears

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shows: return String(localized: "While the text shows")
        case .appears: return String(localized: "When the text appears")
        }
    }
}

/// An area of a display and the words a row waits for there, read by
/// `ScreenTextService` with the Vision text recognizer while the preset
/// runs. Lives in the preset (`Preset.screenTexts`), like screen regions.
/// Bounds are 0 to 1 from the top left of the display named by `display`
/// (the main display when nil or not attached).
struct ScreenTextWatch: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var display: DisplayKey? = nil
    var minX: Double = 0.25
    var minY: Double = 0.25
    var maxX: Double = 0.75
    var maxY: Double = 0.75
    /// The words to look for. Matched ignoring case, accents and extra spaces.
    var text: String = ""
    var mode: ScreenTextMode = .shows
    var colorIndex: Int = 0

    static let maxWatches = 16

    var shownName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Screen text") : "\u{201C}\(t)\u{201D}"
    }

    /// Case, accents, punctuation and runs of spaces folded away, for
    /// matching: the recognizer adds a period or a comma of its own, the
    /// screen shows "Ready!" for ready, and both write a curly apostrophe.
    static func normalized(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "\u{2018}", "\u{2019}": return "'"
            default: return Character(scalar)
            }
        }.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0.isWhitespace }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Every number back inside its range, for a preset edited by hand.
    func clampedValues() -> ScreenTextWatch {
        var w = self
        func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : fallback }
        w.minX = finite(minX, 0.25); w.minY = finite(minY, 0.25)
        w.maxX = finite(maxX, 0.75); w.maxY = finite(maxY, 0.75)
        if w.maxX < w.minX { swap(&w.minX, &w.maxX) }
        if w.maxY < w.minY { swap(&w.minY, &w.maxY) }
        w.colorIndex = max(0, colorIndex)
        return w
    }

    enum CodingKeys: String, CodingKey {
        case id, name, display, minX, minY, maxX, maxY, text, mode, colorIndex
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        display = try? c.decodeIfPresent(DisplayKey.self, forKey: .display)
        minX = (try? c.decode(Double.self, forKey: .minX)) ?? 0.25
        minY = (try? c.decode(Double.self, forKey: .minY)) ?? 0.25
        maxX = (try? c.decode(Double.self, forKey: .maxX)) ?? 0.75
        maxY = (try? c.decode(Double.self, forKey: .maxY)) ?? 0.75
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        mode = (try? c.decode(ScreenTextMode.self, forKey: .mode)) ?? .shows
        colorIndex = (try? c.decode(Int.self, forKey: .colorIndex)) ?? 0
        self = clampedValues()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encode(minX, forKey: .minX)
        try c.encode(minY, forKey: .minY)
        try c.encode(maxX, forKey: .maxX)
        try c.encode(maxY, forKey: .maxY)
        try c.encode(text, forKey: .text)
        try c.encode(mode, forKey: .mode)
        try c.encode(colorIndex, forKey: .colorIndex)
    }
}

/// Words a row waits to hear, recognized on this Mac by `VoicePhraseService`
/// while the preset runs. Lives in the preset (`Preset.voicePhrases`).
struct VoicePhrase: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    /// What to listen for. Matched ignoring case, accents and extra spaces,
    /// as whole words.
    var phrase: String = ""
    var colorIndex: Int = 0

    static let maxPhrases = 32

    var shownName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? String(localized: "Voice phrase") : "\u{201C}\(p)\u{201D}"
    }

    enum CodingKeys: String, CodingKey { case id, name, phrase, colorIndex }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        phrase = (try? c.decode(String.self, forKey: .phrase)) ?? ""
        colorIndex = max(0, (try? c.decode(Int.self, forKey: .colorIndex)) ?? 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(phrase, forKey: .phrase)
        try c.encode(colorIndex, forKey: .colorIndex)
    }
}
