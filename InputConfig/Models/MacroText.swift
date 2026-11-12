import Foundation

/// The row settings the first lines of a macro text can set: when it
/// runs, its playback speed and timing spread, and its repeat. Read from
/// a row with `init(row:)` and written back with `apply(to:)`. A parse
/// result carries nil instead when the text had no option lines, so the
/// row keeps what it has.
struct MacroTextOptions: Equatable {
    var macroInterruptOnRelease: Bool?
    var macroLoop: Bool?
    var macroSpeed: Double?
    var macroJitterPercent: Int?
    var repeatCount: Int?
    var repeatDelayMs: Int?

    /// The playback speeds and timing spreads the row's pickers offer.
    static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    static let jitters: [Int] = [0, 10, 25, 50]

    init(macroInterruptOnRelease: Bool? = nil, macroLoop: Bool? = nil, macroSpeed: Double? = nil,
         macroJitterPercent: Int? = nil, repeatCount: Int? = nil, repeatDelayMs: Int? = nil) {
        self.macroInterruptOnRelease = macroInterruptOnRelease
        self.macroLoop = macroLoop
        self.macroSpeed = macroSpeed
        self.macroJitterPercent = macroJitterPercent
        self.repeatCount = repeatCount
        self.repeatDelayMs = repeatDelayMs
    }

    @MainActor init(row: BindingModel) {
        // A flag left on a toggled or never held row does nothing, and its
        // line would be refused when the row's text comes back.
        macroInterruptOnRelease = row.toggleMode == true || MappingEngine.isNeverHeld(row.input) ? nil : row.macroInterruptOnRelease
        macroLoop = row.macroLoop
        macroSpeed = row.macroSpeed
        macroJitterPercent = row.macroJitterPercent
        repeatCount = row.repeatCount
        repeatDelayMs = row.repeatDelayMs
    }

    /// Sets the six fields on the row, nil for each default the way the
    /// editor's pickers store them.
    func apply(to row: inout BindingModel) {
        row.macroInterruptOnRelease = macroInterruptOnRelease == true ? true : nil
        row.macroLoop = macroLoop == true ? true : nil
        row.macroSpeed = macroSpeed.flatMap { abs($0 - 1) < 0.001 ? nil : $0 }
        row.macroJitterPercent = (macroJitterPercent ?? 0) == 0 ? nil : macroJitterPercent
        row.repeatCount = (repeatCount ?? 1) <= 1 ? nil : repeatCount
        row.repeatDelayMs = repeatDelayMs
    }

    /// The speed as the row's picker shows it: the nearest of its six.
    var pickerSpeed: Double {
        let v = macroSpeed ?? 1
        return Self.speeds.min { abs($0 - v) < abs($1 - v) } ?? 1
    }

    /// The spread as the row's picker shows it.
    var pickerJitter: Int {
        let v = macroJitterPercent ?? 0
        return Self.jitters.min { abs($0 - v) < abs($1 - v) } ?? 0
    }
}

/// One thing the parser has to say about a line: an error keeps Apply
/// off, a note does not.
struct MacroTextIssue: Hashable, Identifiable {
    var line: Int
    var message: String
    var isError: Bool
    var id: MacroTextIssue { self }
}

/// What a macro text parses to.
struct MacroTextResult {
    var steps: [MacroStep]
    /// nil when the text set no option; the row keeps its settings.
    var options: MacroTextOptions?
    var issues: [MacroTextIssue]
    /// True when a step opens an app, a link, a Shortcut, Spotlight or
    /// Launchpad, or types text: the first Apply shows the import review
    /// wording and asks once more.
    var needsSecondClick: Bool
    /// "7 steps, 1.1 s", for the status line.
    var summary: String
    var hasErrors: Bool { issues.contains(where: \.isError) }
}

/// A macro's steps as plain lines, one step per line, and back: the text
/// is a second face on `BindingModel.macroSteps`, which the engine never
/// sees. `write` is canonical (defaults omitted, lowercase, the first
/// word of each table), so writing, parsing and writing again gives the
/// same steps and the same text. Every keyword is English in every
/// language; only the messages are localized.
enum MacroText {
    /// The steps one press plays at most (MacroRecording.maxSteps).
    static let maxSteps = MacroRecording.maxSteps
    /// The gap a step gets when no wait line comes before it.
    private static let defaultMs = 50
    /// The timeout a Wait for screen step gets when none is written.
    private static let defaultTimeoutMs = 10_000

    // MARK: - Words

    /// Left and right Control, Shift, Option and Command.
    private static let modifierCodes: Set<Int> = [224, 225, 226, 227, 228, 229, 230, 231]
    /// The modifier glyphs and AutoHotkey's prefixes, each the left key.
    private static let modifierGlyphs: [Character: Int] = ["\u{2318}": 227, "\u{2325}": 226, "\u{2303}": 224, "\u{21E7}": 225,
                                                            "^": 224, "!": 226, "+": 225]
    private static let autoHotkeyPrefixes: Set<Character> = ["^", "!", "+"]
    /// Words that end a run of key words and start a suffix.
    private static let suffixStarters: Set<String> = ["for", "over", "with", "then"]
    /// The most words a key's name has (keyboard light down).
    private static let longestKeyWord = 3
    /// The first word of every key name, to tell a misspelled key from a
    /// word that is not a step at all.
    private static let keyFirstWords: Set<String> = Set(KeyCodeMap.textWords.compactMap { $0.word.split(separator: " ").first.map(String.init) })
    private static let allKeyWords: [String] = KeyCodeMap.textWords.map(\.word)
    private static let quoteCharacters: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{AB}", "\u{BB}"]

    /// Whether `ch` closes a quote opened with `opener`. A straight quote
    /// is closed only by a straight one, so curly quotes typed inside it
    /// (macOS smart quotes in a Type Text) are part of the text; a curly
    /// one, as smart quotes type the pair, by either curly quote, which
    /// closes the German low quote too. A guillemet, by its partner.
    private static func closesQuote(_ ch: Character, opener: Character) -> Bool {
        switch opener {
        case "\"": return ch == "\""
        case "\u{AB}": return ch == "\u{BB}"
        case "\u{BB}": return ch == "\u{AB}"
        default: return ch == "\u{201C}" || ch == "\u{201D}"
        }
    }
    private static let optionKeys: Set<String> = ["when", "speed", "vary", "repeat"]
    private static let stepVerbs: Set<String> = ["tap", "hold", "release", "wait", "move", "nudge", "click", "scroll", "type", "step", "key"]

    /// Apple's order for written modifiers: ctrl, opt, shift, cmd, the
    /// left key before the right one.
    private static func modifierRank(_ code: Int) -> Int {
        switch code {
        case 224: return 0
        case 228: return 1
        case 226: return 2
        case 230: return 3
        case 225: return 4
        case 229: return 5
        case 227: return 6
        case 231: return 7
        // Clamped: a huge code from a file overflowed on every render.
        default: return 8 + min(max(code, 0), 0xFFFF)
        }
    }

    /// The modifiers without repeats, in the written order.
    static func sortedModifiers(_ codes: [Int]) -> [Int] {
        Array(Set(codes)).sorted { modifierRank($0) < modifierRank($1) }
    }

    /// The modifier a word names (cmd, right opt, a glyph), or nil.
    private static func modifierCode(_ word: String) -> Int? {
        if word.count == 1, let ch = word.first, !autoHotkeyPrefixes.contains(ch), let code = modifierGlyphs[ch] { return code }
        guard let code = KeyCodeMap.code(forTextWord: word), modifierCodes.contains(code) else { return nil }
        return code
    }

    /// The word for a speed on the speed line.
    private static func speedWord(_ speed: Double) -> String {
        switch speed {
        case 0.25: return "quarter"
        case 0.5: return "half"
        case 1.5: return "1.5x"
        case 2: return "2x"
        case 4: return "4x"
        default: return "as recorded"
        }
    }

    // MARK: - Writing

    /// The whole text: an optional `# Macro on <heading>` comment, the
    /// option lines that differ from the defaults, then the steps. A step
    /// whose gap is not 50 ms gets a `wait N` line before it; after a Wait
    /// step the next step's gap is always written, even 50, so a Wait step
    /// never folds into the gap on the way back.
    static func write(steps: [MacroStep], options: MacroTextOptions?, watches: [(id: UUID, name: String)], heading: String?) -> String {
        var lines: [String] = []
        if let heading { lines.append("# Macro on \(heading)") }
        if let options { lines.append(contentsOf: optionLines(options)) }
        var afterWait = false
        for step in steps {
            if (step.eventKind ?? .tap) == .wait {
                lines.append("wait \(step.delayMs)")
                afterWait = true
                continue
            }
            if step.delayMs != defaultMs || afterWait { lines.append("wait \(step.delayMs)") }
            lines.append(writeLine(step, watches: watches))
            afterWait = false
        }
        return lines.joined(separator: "\n")
    }

    /// One step's own line, without the wait before it: the caption under
    /// a step row.
    static func writeLine(_ step: MacroStep, watches: [(id: UUID, name: String)]) -> String {
        let kind = step.eventKind ?? .tap
        switch kind {
        case .wait:
            return "wait \(step.delayMs)"
        case .moveTo:
            var line = "move to \(coordinate(step.action.clickX)), \(coordinate(step.action.clickY))"
            if step.holdMs != defaultMs { line += " over \(step.holdMs)" }
            return line
        case .waitFor:
            var line = "wait for \(watchWord(step.watchID, watches: watches))"
            if let timeout = step.timeoutMs, timeout != defaultTimeoutMs { line += " up to \(timeout)" }
            if step.continueOnTimeout == true { line += ", then go on anyway" }
            return line
        case .tap, .down, .up:
            let verb = kind == .down ? "hold" : kind == .up ? "release" : "tap"
            var body: String
            if step.action.type == .key, let words = step.action.macroTextWords {
                let modifiers = sortedModifiers(step.modifiers ?? []).map { KeyCodeMap.textWord(for: $0) ?? "key \($0)" }
                body = (modifiers + [words]).joined(separator: " ")
                // A bare line of a special key's words would read as the
                // System Function of the same name (volume up, mute) or of
                // its first word (launchpad key, spotlight key).
                // Held or released, the verb alone is read as the System
                // Function (hold volume up), so `key` says it is the key.
                let needsVerb = modifiers.isEmpty && startsWithSystemWord(words)
                if kind != .tap, needsVerb { body = "key " + body }
                if kind != .tap || needsVerb { body = verb + " " + body }
            } else if let words = step.action.macroTextWords {
                body = words
                if step.action.type == .mouseWheelStep, let count = step.count, count > 1 { body += " \(count)" }
                if kind != .tap { body = verb + " " + body }
            } else {
                body = "step " + stepJSON(step.action)
                if kind != .tap { body = verb + " " + body }
            }
            if step.holdMs != defaultMs { body += " for \(step.holdMs)" }
            return body
        }
    }

    private static func optionLines(_ options: MacroTextOptions) -> [String] {
        var out: [String] = []
        let loop = options.macroLoop == true
        if loop {
            out.append("when: until pressed again")
        } else if options.macroInterruptOnRelease == true {
            out.append("when: while held")
        }
        let speed = options.pickerSpeed
        if speed != 1 { out.append("speed: \(speedWord(speed))") }
        let jitter = options.pickerJitter
        if jitter != 0 { out.append("vary: \(jitter)%") }
        let between = options.repeatDelayMs.map { "\($0) between" }
        if loop {
            // The count means nothing under a loop; only the pause between passes.
            if let between { out.append("repeat: \(between)") }
        } else if let count = options.repeatCount, count > 1 {
            out.append("repeat: \(count) times" + (between.map { ", \($0)" } ?? ""))
        }
        return out
    }

    /// A point's coordinate: whole numbers, with a point never a comma.
    private static func coordinate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "0" }
        return "\(Int(min(max(value, -100_000), 100_000).rounded()))"
    }

    /// How a Wait for screen step names its watch: the name in quotes when
    /// it is unique, else `#n`, its 1-based place in the list (screen
    /// colors first, then screen texts). A watch the list does not have
    /// writes its id, which parses to an error naming it.
    private static func watchWord(_ id: UUID?, watches: [(id: UUID, name: String)]) -> String {
        guard let id, let index = watches.firstIndex(where: { $0.id == id }) else {
            return OutputAction.macroTextQuoted(id?.uuidString ?? "")
        }
        let name = watches[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, watches.filter({ $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }).count == 1 {
            return OutputAction.macroTextQuoted(name)
        }
        return "#\(index + 1)"
    }

    /// An output as the app writes it on a `step` line: its JSON with the
    /// keys sorted and the id left out (a parse gives it a new one).
    static func stepJSON(_ action: OutputAction) -> String {
        guard let data = try? JSONEncoder().encode(action),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
        object["id"] = nil
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: out, as: UTF8.self)
    }

    /// The output a `step` line's JSON decodes to, or nil when it is not
    /// one output as the app wrote it.
    private static func decodeStepJSON(_ json: String) -> OutputAction? {
        guard let data = json.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if object["id"] == nil { object["id"] = UUID().uuidString }
        guard let fixed = try? JSONSerialization.data(withJSONObject: object),
              let action = try? JSONDecoder().decode(OutputAction.self, from: fixed) else { return nil }
        return action
    }

    // MARK: - Text helpers

    /// The text's lines, a Windows line break counting as one, and the
    /// Unicode line breaks a paste from Pages or Word brings counting too:
    /// the pane shows each as a new line.
    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(omittingEmptySubsequences: false) { "\n\u{2028}\u{2029}\u{85}".contains($0) }.map(String.init)
    }

    /// The blocks of a text that holds several macros, split where a
    /// `# Macro on` heading starts one; the heading stays in its block.
    static func blocks(_ text: String) -> [String] {
        var out: [[String]] = []
        var current: [String] = []
        func hasContent(_ block: [String]) -> Bool { block.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        for line in lines(of: text) {
            if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("# macro on") {
                if hasContent(current) { out.append(current) }
                current = []
            }
            current.append(line)
        }
        if hasContent(current) { out.append(current) }
        return out.map { $0.joined(separator: "\n").trimmingCharacters(in: .newlines) }
    }

    /// Whether a text's first real line is a macro option or step, so an
    /// import can tell a pasted macro from a preset file.
    static func looksLikeMacro(_ text: String) -> Bool {
        for raw in lines(of: text) {
            let code = stripComment(raw).code.trimmingCharacters(in: .whitespaces)
            if code.isEmpty { continue }
            if code.hasPrefix("{") || code.hasPrefix("[") { return false }
            if optionLine(code) != nil { return true }
            if let first = tokenize(code).tokens.first?.word, stepVerbs.contains(first) { return true }
            let result = parse(code, watches: [], currentOptions: MacroTextOptions())
            return !result.hasErrors && !result.steps.isEmpty
        }
        return false
    }

    /// The word within two edits of `word` that is nearest, or nil.
    static func nearest(_ word: String, in words: [String]) -> String? {
        let w = word.lowercased()
        var best: (word: String, distance: Int)?
        for candidate in words {
            let d = editDistance(w, candidate.lowercased())
            if d <= 2, best == nil || d < best!.distance { best = (candidate, d) }
        }
        return best?.word
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 2 { return 3 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Milliseconds from a time token: a bare number is milliseconds, `ms`
    /// too, `s` is seconds (`1.5s`, also `1,5s`). nil for anything else.
    static func parseDuration(_ token: String) -> Int? {
        var t = token.lowercased().trimmingCharacters(in: .whitespaces)
        var seconds = false
        if t.hasSuffix("ms") {
            t.removeLast(2)
        } else if t.hasSuffix("s") {
            t.removeLast()
            seconds = true
        }
        if seconds, isCommaDecimal(t) { t = t.replacingOccurrences(of: ",", with: ".") }
        guard !t.isEmpty, t.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }),
              let value = Double(t), value.isFinite else { return nil }
        let ms = seconds ? value * 1000 : value
        guard abs(ms) < 1_000_000_000 else { return nil }
        return Int(ms.rounded())
    }

    /// Digits, a comma, digits: a decimal written the European way.
    private static func isCommaDecimal(_ text: String) -> Bool {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// `x3` on a line: the count, or nil for any other word.
    private static func repeatSuffix(_ word: String) -> Int? {
        guard word.count > 1, word.hasPrefix("x"), let n = Int(word.dropFirst()), n >= 0 else { return nil }
        return n
    }

    /// The line without its comment (`#` outside quotes to the end), and
    /// whether it had one. `#3` right after `wait for` is a watch number.
    private static func stripComment(_ line: String) -> (code: String, hadComment: Bool) {
        var opener: Character?
        var out = ""
        let chars = Array(line)
        for (i, ch) in chars.enumerated() {
            if let open = opener {
                if closesQuote(ch, opener: open) { opener = nil }
            } else if quoteCharacters.contains(ch) {
                opener = ch
            } else if ch == "#" {
                let watchNumber = i + 1 < chars.count && chars[i + 1].isNumber
                    && out.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("wait for")
                if !watchNumber { return (out, true) }
            }
            out.append(ch)
        }
        return (out, false)
    }

    private enum Token: Equatable {
        /// A word, lowercased.
        case word(String)
        /// Text between quotes, as typed, two quotes read as one.
        case quoted(String)

        var word: String? {
            if case .word(let w) = self { return w }
            return nil
        }
        var quoted: String? {
            if case .quoted(let q) = self { return q }
            return nil
        }
    }

    /// The words and quoted strings of a line. Commas separate, except
    /// between two digits (`1,5s`, which the parser names).
    private static func tokenize(_ code: String) -> (tokens: [Token], unterminated: Bool) {
        var tokens: [Token] = []
        var word = ""
        var quoted = ""
        var inQuote = false
        var opener: Character = "\""
        let chars = Array(code)
        var i = 0
        func flush() {
            if !word.isEmpty { tokens.append(.word(word.lowercased())); word = "" }
        }
        while i < chars.count {
            let ch = chars[i]
            if inQuote {
                if closesQuote(ch, opener: opener) {
                    if ch == "\"", i + 1 < chars.count, chars[i + 1] == "\"" {
                        quoted.append("\"")
                        i += 2
                        continue
                    }
                    tokens.append(.quoted(quoted))
                    quoted = ""
                    inQuote = false
                } else {
                    quoted.append(ch)
                }
            } else if quoteCharacters.contains(ch) {
                flush()
                inQuote = true
                opener = ch
            } else if ch.isWhitespace {
                flush()
            } else if ch == "," {
                if let last = word.last, last.isNumber, i + 1 < chars.count, chars[i + 1].isNumber {
                    word.append(ch)
                } else {
                    flush()
                }
            } else {
                word.append(ch)
            }
            i += 1
        }
        flush()
        return (tokens, inQuote)
    }

    /// An option line's key and value, or nil for a step line.
    private static func optionLine(_ code: String) -> (key: String, value: String)? {
        guard let colon = code.firstIndex(of: ":") else { return nil }
        let key = code[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard optionKeys.contains(key) else { return nil }
        return (key, code[code.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// A `step {json}` line, with an optional kind word before `step` and
    /// suffixes after the JSON. nil for any other line; an empty `json`
    /// for a `step` line with no object.
    private static func jsonStepLine(_ raw: String) -> (kind: MacroStepKind, json: String, rest: String)? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        var kind: MacroStepKind = .tap
        for (verb, verbKind) in [("hold", MacroStepKind.down), ("release", .up), ("tap", .tap)] {
            if text.lowercased().hasPrefix(verb + " ") {
                kind = verbKind
                text = text.dropFirst(verb.count).drop(while: \.isWhitespace)
                break
            }
        }
        guard text.lowercased().hasPrefix("step") else { return nil }
        let afterVerb = text.dropFirst(4)
        guard afterVerb.isEmpty || afterVerb.first!.isWhitespace || afterVerb.first == "{" else { return nil }
        let body = afterVerb.drop(while: \.isWhitespace)
        guard body.first == "{" else { return (kind, "", String(body)) }
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, ch) in body.enumerated() {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let end = body.index(body.startIndex, offsetBy: offset + 1)
                    return (kind, String(body[..<end]), String(body[end...]))
                }
            default: break
            }
        }
        return (kind, "", "")
    }

    // MARK: - Parsing

    private struct Context {
        let watches: [(id: UUID, name: String)]
        let current: MacroTextOptions
        let cap: Int
        let isToggle: Bool
        let neverHeld: Bool
        var steps: [MacroStep] = []
        var pendingWaits: [(ms: Int, line: Int)] = []
        var sawStep = false
        var options: MacroTextOptions?
        var issues: [MacroTextIssue] = []
        var commentLines = 0
        var firstCommentLine = 0
        var held: [(key: String, line: Int)] = []
        var capNoted = false
        var repeatCountLine: Int?

        mutating func error(_ line: Int, _ message: String) {
            issues.append(MacroTextIssue(line: line, message: message, isError: true))
        }
        mutating func note(_ line: Int, _ message: String) {
            issues.append(MacroTextIssue(line: line, message: message, isError: false))
        }
    }

    /// What a line's suffixes said.
    private struct Suffixes {
        var holdMs: Int?
        var glideMs: Int?
        var times: Int?
        var modifiers: [Int] = []
        var hasWith = false
        var timeoutMs: Int?
        var continueOnTimeout: Bool?
    }

    /// Reads a text into steps. `watches` are the preset's screen colors
    /// then screen texts, each with its own name (empty when it has
    /// none); `currentOptions` are the row's settings an option line
    /// starts from; `currentCount` the steps the row has now, so a row
    /// already past 200 can still be edited; `isToggle` and `neverHeld`
    /// say whether `when: while held` can mean anything on the row.
    static func parse(_ text: String, watches: [(id: UUID, name: String)], currentOptions: MacroTextOptions,
                      currentCount: Int = 0, isToggle: Bool = false, neverHeld: Bool = false) -> MacroTextResult {
        var ctx = Context(watches: watches, current: currentOptions, cap: max(maxSteps, currentCount),
                          isToggle: isToggle, neverHeld: neverHeld)
        for (i, raw) in lines(of: text).enumerated() {
            parseLine(raw, number: i + 1, ctx: &ctx)
        }
        finish(&ctx)
        return MacroTextResult(steps: ctx.steps, options: ctx.options, issues: ctx.issues,
                               needsSecondClick: ctx.steps.contains { $0.action.opensSomething } || SpotlightChord.inMacro(ctx.steps),
                               summary: summary(ctx.steps))
    }

    private static func summary(_ steps: [MacroStep]) -> String {
        var ms = 0
        for step in steps {
            ms += step.delayMs
            switch step.eventKind ?? .tap {
            case .wait, .waitFor: break
            default: ms += step.holdMs
            }
        }
        let seconds = (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1)))
        return steps.count == 1 ? String(localized: "1 step, \(seconds) s") : String(localized: "\(steps.count) steps, \(seconds) s")
    }

    private static func finish(_ ctx: inout Context) {
        // Trailing waits are Wait steps.
        let trailing = ctx.pendingWaits
        ctx.pendingWaits = []
        for wait in trailing { push(waitStep(wait.ms), line: wait.line, fromRepeat: false, ctx: &ctx) }
        for held in ctx.held {
            ctx.note(held.line, String(localized: "Line \(held.line): this hold is never released; it is released when the macro ends."))
        }
        if let line = ctx.repeatCountLine, ctx.options?.macroLoop == true {
            ctx.note(line, String(localized: "Line \(line): under until pressed again the count is ignored; the steps repeat until the next press."))
        }
        if ctx.commentLines == 1 {
            ctx.note(ctx.firstCommentLine, String(localized: "1 comment line will be dropped; steps have no notes."))
        } else if ctx.commentLines > 1 {
            ctx.note(ctx.firstCommentLine, String(localized: "\(ctx.commentLines) comment lines will be dropped; steps have no notes."))
        }
    }

    private static func parseLine(_ raw: String, number line: Int, ctx: inout Context) {
        // A step line carries one output's JSON, with quotes and braces of its own.
        if let json = jsonStepLine(raw) {
            ctx.sawStep = true
            parseJSONStep(json.kind, json: json.json, rest: json.rest, line: line, ctx: &ctx)
            return
        }
        let stripped = stripComment(raw)
        if stripped.hadComment {
            ctx.commentLines += 1
            if ctx.firstCommentLine == 0 { ctx.firstCommentLine = line }
        }
        var code = stripped.code.trimmingCharacters(in: .whitespaces)
        if code.isEmpty { return }
        if let option = optionLine(code) {
            parseOption(option.key, value: option.value, line: line, ctx: &ctx)
            return
        }
        ctx.sawStep = true
        // AutoHotkey's braces: {cmd down}, {cmd up}, {Enter}.
        if code.hasPrefix("{"), code.hasSuffix("}"), code.count > 2 {
            let inner = code.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            let lower = inner.lowercased()
            let rewritten: String
            if lower.hasSuffix(" down") {
                rewritten = "hold " + inner.dropLast(5).trimmingCharacters(in: .whitespaces)
            } else if lower.hasSuffix(" up") {
                rewritten = "release " + inner.dropLast(3).trimmingCharacters(in: .whitespaces)
            } else {
                rewritten = inner
            }
            ctx.note(line, String(localized: "Line \(line): \(code) read as \(rewritten.lowercased())."))
            code = rewritten
        }
        let tokenized = tokenize(code)
        if tokenized.unterminated {
            ctx.error(line, String(localized: "Line \(line): a quote is not closed; two quotes in a row stand for one."))
            return
        }
        guard let first = tokenized.tokens.first else { return }
        let tokens = tokenized.tokens
        guard let word = first.word else {
            ctx.error(line, quotesMessage(first.quoted ?? "", line: line))
            return
        }
        switch word {
        case "wait":
            if tokens.count > 1, tokens[1].word == "for" {
                parseWaitFor(tokens[2...], line: line, ctx: &ctx)
            } else {
                parseWait(tokens[1...], line: line, ctx: &ctx)
            }
        case "tap":
            parseVerbStep(.tap, tokens[1...], verb: word, line: line, ctx: &ctx)
        case "hold":
            parseVerbStep(.down, tokens[1...], verb: word, line: line, ctx: &ctx)
        case "release":
            parseVerbStep(.up, tokens[1...], verb: word, line: line, ctx: &ctx)
        case "move":
            guard tokens.count > 1, tokens[1].word == "to" else {
                ctx.error(line, moveMessage(line))
                return
            }
            parseMove(tokens[2...], line: line, ctx: &ctx)
        case "type":
            parseType(.tap, tokens[1...], line: line, ctx: &ctx)
        case "scroll":
            parseScroll(.tap, tokens[1...], line: line, ctx: &ctx)
        case "nudge":
            parseNudge(tokens[1...], line: line, ctx: &ctx)
        case "key":
            parseKeyMarked(.tap, tokens[1...], verb: nil, line: line, ctx: &ctx)
        case "step":
            ctx.error(line, jsonMessage(line))
        default:
            if let click = clickWords(tokens[0...]) {
                parseWordAction(.tap, verb: click.verb, args: click.args, tokens[click.end...], line: line, ctx: &ctx)
            } else if let system = systemWords(tokens[0...]), endsSystemWords(tokens[system.end...]) {
                parseSystem(.tap, system.word, kind: system.kind, tokens[system.end...], line: line, ctx: &ctx)
            } else if isKeyStart(word) {
                parseKeyStep(.tap, tokens[0...], verb: nil, line: line, ctx: &ctx)
            } else if let system = systemWords(tokens[0...]) {
                // open app Safari: what follows is the problem, not the words.
                parseSystem(.tap, system.word, kind: system.kind, tokens[system.end...], line: line, ctx: &ctx)
            } else if let suggestion = nearest(word, in: allKeyWords) {
                ctx.error(line, String(localized: "Line \(line): no key called \(word). Did you mean \(suggestion)?"))
            } else {
                ctx.error(line, String(localized: "Line \(line): \(word) is not a step. Lines start with tap, hold, release, wait, wait for, move to, click, scroll, type, open app, open url, run shortcut, a key or a system function."))
            }
        }
    }

    // MARK: Options

    private static func parseOption(_ key: String, value: String, line: Int, ctx: inout Context) {
        if ctx.sawStep {
            ctx.error(line, String(localized: "Line \(line): \(key): belongs at the top."))
            return
        }
        var options = ctx.options ?? ctx.current
        let v = value.lowercased().split(separator: " ").joined(separator: " ")
        switch key {
        case "when":
            switch v {
            case "every press", "each press", "every step", "each time":
                options.macroInterruptOnRelease = nil
                options.macroLoop = nil
            case "while held", "only while held":
                if ctx.isToggle {
                    ctx.error(line, String(localized: "Line \(line): this row toggles, so while held cannot stop it."))
                    return
                }
                if ctx.neverHeld {
                    ctx.error(line, String(localized: "Line \(line): this input is never held; use every press."))
                    return
                }
                options.macroInterruptOnRelease = true
                options.macroLoop = nil
            case "until pressed again", "pressed again", "again and again":
                options.macroInterruptOnRelease = nil
                options.macroLoop = true
            default:
                ctx.error(line, String(localized: "Line \(line): when is every press, while held or until pressed again."))
                return
            }
        case "speed":
            let speed: Double?
            switch v {
            case "quarter": speed = 0.25
            case "half": speed = 0.5
            case "as recorded", "recorded", "normal": speed = 1
            default:
                let number = v.hasSuffix("x") ? String(v.dropLast()) : v
                speed = Double(number).flatMap { n in MacroTextOptions.speeds.first { abs($0 - n) < 0.001 } }
            }
            guard let speed else {
                ctx.error(line, String(localized: "Line \(line): speed is quarter, half, as recorded, 1.5x, 2x or 4x."))
                return
            }
            options.macroSpeed = speed == 1 ? nil : speed
        case "vary":
            let number = v.hasSuffix("%") ? String(v.dropLast()).trimmingCharacters(in: .whitespaces) : v
            guard let jitter = Int(number), MacroTextOptions.jitters.contains(jitter) else {
                ctx.error(line, String(localized: "Line \(line): vary is 0, 10, 25 or 50%."))
                return
            }
            options.macroJitterPercent = jitter == 0 ? nil : jitter
        case "repeat":
            guard let repeatValue = parseRepeat(v, line: line, ctx: &ctx) else { return }
            if let count = repeatValue.count {
                options.repeatCount = count
                ctx.repeatCountLine = line
            }
            if let between = repeatValue.between { options.repeatDelayMs = between }
        default:
            return
        }
        ctx.options = options
    }

    /// `3 times, 500 between`, `3 times`, `3`, or `500 between`.
    private static func parseRepeat(_ value: String, line: Int, ctx: inout Context) -> (count: Int?, between: Int?)? {
        let words = tokenize(value).tokens.compactMap(\.word)
        var i = 0
        var count: Int?
        var between: Int?
        func fail() -> (count: Int?, between: Int?)? {
            ctx.error(line, String(localized: "Line \(line): repeat is a count and a wait, as in repeat: 3 times, 500 between."))
            return nil
        }
        if i < words.count, let n = Int(words[i]), words.count == 1 || (i + 1 < words.count && ["time", "times"].contains(words[i + 1])) {
            count = n
            i += words.count == 1 ? 1 : 2
        }
        if i < words.count {
            let token = words[i]
            if isCommaDecimal(token.hasSuffix("ms") ? String(token.dropLast(2)) : token) {
                ctx.error(line, commaMessage(line))
                return nil
            }
            guard let ms = parseDuration(token) else { return fail() }
            i += 1
            if i < words.count, words[i] == "ms" { i += 1 }
            guard i < words.count, words[i] == "between" else { return fail() }
            i += 1
            between = ms
        }
        guard i == words.count, count != nil || between != nil else { return fail() }
        if let n = count {
            count = clampNoted(n, 0...1000, what: "repeat", line: line, ctx: &ctx)
            if n > 100 { ctx.note(line, String(localized: "Line \(line): repeat plays at most 100 times.")) }
        }
        if let ms = between {
            between = clampNoted(ms, 0...60_000, what: "between", line: line, ctx: &ctx)
            if ms > 30_000 { ctx.note(line, String(localized: "Line \(line): waits at most 30 s between passes.")) }
        }
        return (count, between)
    }

    // MARK: Steps

    private static func waitStep(_ ms: Int) -> MacroStep {
        MacroStep(action: OutputAction(type: .key, keyCode: 4), delayMs: ms, holdMs: defaultMs, eventKind: .wait)
    }

    /// A copy with a new id.
    private static func copy(of step: MacroStep) -> MacroStep {
        MacroStep(action: step.action, delayMs: step.delayMs, holdMs: step.holdMs, eventKind: step.eventKind,
                  modifiers: step.modifiers, count: step.count, watchID: step.watchID,
                  timeoutMs: step.timeoutMs, continueOnTimeout: step.continueOnTimeout)
    }

    /// Adds one step, keeping count against the cap.
    private static func push(_ step: MacroStep, line: Int, fromRepeat: Bool, ctx: inout Context) {
        if ctx.steps.count >= ctx.cap {
            if fromRepeat {
                ctx.error(line, String(localized: "Line \(line): x makes more than \(ctx.cap) steps; a macro plays at most \(maxSteps)."))
                return
            }
            // Left out, as the load would cut them at the next launch: what
            // Apply writes is what plays and what stays.
            if !ctx.capNoted {
                ctx.capNoted = true
                ctx.note(line, String(localized: "Line \(line): more than \(ctx.cap) steps; a macro plays at most \(maxSteps)."))
            }
            return
        }
        ctx.steps.append(step)
    }

    /// Adds a parsed step: the last pending wait is its gap, earlier ones
    /// Wait steps before it; `times` copies it.
    private static func emit(_ step: MacroStep, times: Int?, line: Int, ctx: inout Context) {
        var first = step
        if let last = ctx.pendingWaits.last {
            for wait in ctx.pendingWaits.dropLast() { push(waitStep(wait.ms), line: wait.line, fromRepeat: false, ctx: &ctx) }
            first.delayMs = last.ms
            ctx.pendingWaits = []
        }
        let kind = first.eventKind ?? .tap
        if kind.presses {
            let key = first.pressedActions.map(\.serialized).joined(separator: "|")
            let fn = first.action.type == .key && first.action.keyCode == KeyCodeMap.globeFnCode
            if kind == .down, !fn {
                ctx.held.append((key, line))
            } else if kind == .up, !fn {
                if let i = ctx.held.lastIndex(where: { $0.key == key }) {
                    ctx.held.remove(at: i)
                } else {
                    ctx.note(line, String(localized: "Line \(line): nothing is held for this release; it is released anyway."))
                }
            }
        }
        push(first, line: line, fromRepeat: false, ctx: &ctx)
        if let times, times > 1 {
            for _ in 1..<times {
                if ctx.steps.count >= ctx.cap {
                    push(copy(of: first), line: line, fromRepeat: true, ctx: &ctx)
                    return
                }
                push(copy(of: first), line: line, fromRepeat: true, ctx: &ctx)
            }
        }
    }

    private static func parseWait(_ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        guard let first = tokens.first else {
            ctx.error(line, waitMessage(line))
            return
        }
        guard let ms = readMs(first, line: line, missing: waitMessage(line), ctx: &ctx) else { return }
        if tokens.count > 1 {
            ctx.error(line, String(localized: "Line \(line): could not read \(tokens[tokens.startIndex + 1].word ?? "") after wait."))
            return
        }
        ctx.pendingWaits.append((clampNoted(ms, MacroStep.waitRange, what: "wait", line: line, ctx: &ctx), line))
    }

    private static func parseWaitFor(_ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        guard let first = tokens.first else {
            ctx.error(line, waitForMessage(line))
            return
        }
        let watchID: UUID?
        if let name = first.quoted, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A step whose watch is not picked yet (the list writes it so):
            // kept, with a note, as the list keeps it; it waits for nothing.
            ctx.note(line, String(localized: "Line \(line): pick the screen color or text for this step in the list."))
            watchID = nil
        } else if let name = first.quoted {
            let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = ctx.watches.enumerated().filter { $0.element.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame }
            if matches.count == 1 {
                watchID = matches[0].element.id
            } else if matches.isEmpty {
                let names = ctx.watches.enumerated().map { entry -> String in
                    let n = entry.element.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return n.isEmpty ? "#\(entry.offset + 1)" : n
                }
                if names.isEmpty {
                    ctx.error(line, String(localized: "Line \(line): no screen color or text called \(wanted). This preset has none."))
                } else {
                    let list = names.joined(separator: ", ")
                    ctx.error(line, String(localized: "Line \(line): no screen color or text called \(wanted). This preset has: \(list)."))
                }
                return
            } else {
                let alternatives = matches.map { "wait for #\($0.offset + 1)" }.joined(separator: " or ")
                ctx.error(line, String(localized: "Line \(line): \(matches.count) watches are called \(wanted); write \(alternatives)."))
                return
            }
        } else if let word = first.word, word.hasPrefix("#"), let n = Int(word.dropFirst()) {
            guard n >= 1, n <= ctx.watches.count else {
                ctx.error(line, String(localized: "Line \(line): no screen color or text #\(n); this preset has \(ctx.watches.count)."))
                return
            }
            watchID = ctx.watches[n - 1].id
        } else {
            ctx.error(line, waitForMessage(line))
            return
        }
        guard let suffixes = parseSuffixes(tokens.dropFirst(), verb: "wait for", line: line, ctx: &ctx) else { return }
        if suffixes.hasWith {
            ctx.error(line, withMessage(line))
            return
        }
        if suffixes.holdMs != nil || suffixes.glideMs != nil {
            ctx.error(line, String(localized: "Line \(line): wait for takes up to and then: wait for \"Save dialog\" up to 5s, then go on anyway."))
            return
        }
        let step = MacroStep(action: OutputAction(type: .key, keyCode: 4), delayMs: defaultMs, holdMs: defaultMs, eventKind: .waitFor,
                             watchID: watchID,
                             timeoutMs: suffixes.timeoutMs == defaultTimeoutMs ? nil : suffixes.timeoutMs,
                             continueOnTimeout: suffixes.continueOnTimeout == true ? true : nil)
        emit(step, times: suffixes.times, line: line, ctx: &ctx)
    }

    private static func parseMove(_ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        var numbers: [Int] = []
        var i = tokens.startIndex
        while i < tokens.endIndex, numbers.count < 2, let word = tokens[i].word {
            if let n = Int(word) {
                numbers.append(n)
            } else if isCommaDecimal(word) {
                // 640,400 with no space: two whole numbers.
                let parts = word.split(separator: ",").compactMap { Int($0) }
                numbers.append(contentsOf: parts)
            } else {
                break
            }
            i += 1
        }
        guard numbers.count == 2 else {
            ctx.error(line, moveMessage(line))
            return
        }
        guard let suffixes = parseSuffixes(tokens[i...], verb: "move to", line: line, ctx: &ctx) else { return }
        if suffixes.hasWith {
            ctx.error(line, withMessage(line))
            return
        }
        if suffixes.holdMs != nil {
            ctx.error(line, String(localized: "Line \(line): a move glides over its time: move to 640, 400 over 250."))
            return
        }
        if suffixes.timeoutMs != nil || suffixes.continueOnTimeout != nil {
            ctx.error(line, waitForOnlyMessage(line))
            return
        }
        var action = OutputAction(type: .mouseMotion)
        action.clickX = Double(numbers[0])
        action.clickY = Double(numbers[1])
        let step = MacroStep(action: action, delayMs: defaultMs, holdMs: suffixes.glideMs ?? defaultMs, eventKind: .moveTo).clamped()
        emit(step, times: suffixes.times, line: line, ctx: &ctx)
    }

    private static func parseType(_ kind: MacroStepKind, _ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        guard let first = tokens.first, var text = first.quoted else {
            ctx.error(line, String(localized: "Line \(line): type needs quotes: type \"hello\"."))
            return
        }
        if text.count > Preset.importTextLimit {
            text = String(text.prefix(Preset.importTextLimit))
            ctx.note(line, String(localized: "Line \(line): the text is cut at \(Preset.importTextLimit) characters."))
        }
        guard let action = OutputAction.fromMacroText(verb: "type", args: [text]) else { return }
        finishPressingStep(kind, action: action, verb: "type", tokens.dropFirst(), line: line, ctx: &ctx)
    }

    private static func parseScroll(_ kind: MacroStepKind, _ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        guard let direction = tokens.first?.word, let action = OutputAction.fromMacroText(verb: "scroll", args: [direction]) else {
            ctx.error(line, String(localized: "Line \(line): scroll needs a direction: scroll up, down, left or right, then the lines."))
            return
        }
        var rest = tokens.dropFirst()
        var count: Int?
        if let word = rest.first?.word, let n = Int(word) {
            count = clampNoted(n, MacroStep.countRange, what: "count", line: line, ctx: &ctx)
            rest = rest.dropFirst()
        }
        guard let suffixes = parseSuffixes(rest, verb: "scroll", line: line, ctx: &ctx),
              checkPressingSuffixes(suffixes, isKey: false, line: line, ctx: &ctx) else { return }
        var lines = count ?? 1
        if let times = suffixes.times, times > 1 {
            // Repeating a scroll adds up to one longer scroll.
            lines = clampNoted(lines * times, MacroStep.countRange, what: "count", line: line, ctx: &ctx)
        }
        let step = MacroStep(action: action, delayMs: defaultMs, holdMs: suffixes.holdMs ?? defaultMs,
                             eventKind: kind == .tap ? nil : kind, count: lines > 1 ? lines : nil).clamped()
        emit(step, times: nil, line: line, ctx: &ctx)
    }

    /// `nudge up 10`: a Move pointer by step, as the writer puts it; a
    /// direction (up-left and the other diagonals too), then the distance.
    private static func parseNudge(_ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        var args: [String] = []
        if let direction = tokens.first?.word { args.append(direction) }
        var rest = tokens.dropFirst()
        if let word = rest.first?.word, let distance = Int(word) {
            args.append(String(clampNoted(distance, 1...500, what: "nudge", line: line, ctx: &ctx)))
            rest = rest.dropFirst()
        }
        guard let action = OutputAction.fromMacroText(verb: "nudge", args: args) else {
            ctx.error(line, String(localized: "Line \(line): nudge needs a direction: nudge up, down, left, right or a diagonal such as up-left, then the distance."))
            return
        }
        finishPressingStep(.tap, action: action, verb: "nudge", rest, line: line, ctx: &ctx)
    }

    /// After `key`: a code number (key 2047), or a key named by its words
    /// (hold key volume up), which is the key and never the System Function.
    private static func parseKeyMarked(_ kind: MacroStepKind, _ tokens: ArraySlice<Token>, verb: String?, line: Int, ctx: inout Context) {
        if let word = tokens.first?.word, Int(word) == nil, isKeyStart(word) {
            parseKeyStep(kind, tokens, verb: verb, line: line, ctx: &ctx)
        } else {
            parseKeyNumber(kind, tokens, line: line, ctx: &ctx)
        }
    }

    private static func parseKeyNumber(_ kind: MacroStepKind, _ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        guard let word = tokens.first?.word, let action = OutputAction.fromMacroText(verb: "key", args: [word]) else {
            ctx.error(line, String(localized: "Line \(line): key needs a code number: key 2047."))
            return
        }
        finishKeyStep(kind, action: action, modifiers: [], verb: "key", tokens.dropFirst(), line: line, ctx: &ctx)
    }

    /// A click or a System Function with its words already read.
    private static func parseWordAction(_ kind: MacroStepKind, verb: String, args: [String], _ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        guard let action = OutputAction.fromMacroText(verb: verb, args: args) else {
            ctx.error(line, String(localized: "Line \(line): mouse needs a button number, 0 to 31: mouse 4."))
            return
        }
        finishPressingStep(kind, action: action, verb: verb, tokens, line: line, ctx: &ctx)
    }

    private static func parseSystem(_ kind: MacroStepKind, _ word: String, kind systemKind: SystemActionKind, _ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        var rest = tokens
        var args: [String] = []
        if systemKind.needsParameter {
            guard let parameter = rest.first?.quoted else {
                let example: String
                switch systemKind {
                case .openURL: example = "https://example.com"
                case .runShortcut: example = "Start Timer"
                default: example = "Safari"
                }
                ctx.error(line, String(localized: "Line \(line): \(word) needs its name in quotes: \(word) \"\(example)\"."))
                return
            }
            var text = parameter
            if text.count > Preset.importTextLimit {
                text = String(text.prefix(Preset.importTextLimit))
                ctx.note(line, String(localized: "Line \(line): the text is cut at \(Preset.importTextLimit) characters."))
            }
            args = [text]
            rest = rest.dropFirst()
        }
        guard let action = OutputAction.fromMacroText(verb: word, args: args) else { return }
        // A system function fires once: "release volume up" made a step that
        // played nothing, and "hold" one that the list showed as a press.
        if kind == .up {
            ctx.note(line, String(localized: "Line \(line): \(word) has nothing to release; this line is left out."))
            return
        }
        finishPressingStep(kind == .down ? .tap : kind, action: action, verb: word, rest, line: line, ctx: &ctx)
    }

    /// A step after tap, hold or release: a key or chord first, else a
    /// click, a key code, a scroll, typed text or a System Function.
    private static func parseVerbStep(_ kind: MacroStepKind, _ tokens: ArraySlice<Token>, verb: String, line: Int, ctx: inout Context) {
        guard let first = tokens.first else {
            ctx.error(line, String(localized: "Line \(line): \(verb) needs a key: \(verb) shift."))
            return
        }
        guard let word = first.word else {
            ctx.error(line, quotesMessage(first.quoted ?? "", line: line))
            return
        }
        if let click = clickWords(tokens) {
            parseWordAction(kind, verb: click.verb, args: click.args, tokens[click.end...], line: line, ctx: &ctx)
        } else if word == "key" {
            parseKeyMarked(kind, tokens.dropFirst(), verb: verb, line: line, ctx: &ctx)
        } else if kind != .tap, ["scroll", "type", "nudge"].contains(word) {
            // A step with nothing to hold fired once and its release did nothing.
            ctx.error(line, String(localized: "Line \(line): \(verb) works on keys and mouse buttons, not \(word)."))
        } else if word == "scroll" {
            parseScroll(kind, tokens.dropFirst(), line: line, ctx: &ctx)
        } else if word == "type" {
            parseType(kind, tokens.dropFirst(), line: line, ctx: &ctx)
        } else if kind != .tap, let system = systemWords(tokens), endsSystemWords(tokens[system.end...]) {
            // Before the keys, as on a plain line: hold volume up is the
            // System Function, not the key its first word also names. Not
            // for tap: the writer's tap volume up is the key, and the verb
            // is what keeps it one.
            parseSystem(kind, system.word, kind: system.kind, tokens[system.end...], line: line, ctx: &ctx)
        } else if isKeyStart(word) {
            // tap launchpad: the word starts a key's name (launchpad key),
            // and only the System Function reads whole.
            var trial = ctx
            if parseChord(tokens, verb: verb, line: line, ctx: &trial) == nil, let system = systemWords(tokens) {
                parseSystem(kind, system.word, kind: system.kind, tokens[system.end...], line: line, ctx: &ctx)
            } else {
                parseKeyStep(kind, tokens, verb: verb, line: line, ctx: &ctx)
            }
        } else if let system = systemWords(tokens) {
            parseSystem(kind, system.word, kind: system.kind, tokens[system.end...], line: line, ctx: &ctx)
        } else if let suggestion = nearest(word, in: allKeyWords) {
            ctx.error(line, String(localized: "Line \(line): no key called \(word). Did you mean \(suggestion)?"))
        } else {
            ctx.error(line, String(localized: "Line \(line): no key called \(word)."))
        }
    }

    /// A key or chord line: the key words, then the suffixes.
    private static func parseKeyStep(_ kind: MacroStepKind, _ tokens: ArraySlice<Token>, verb: String?, line: Int, ctx: inout Context) {
        guard let chord = parseChord(tokens, verb: verb, line: line, ctx: &ctx) else { return }
        let action = OutputAction(type: .key, keyCode: chord.key)
        guard finishKeyStep(kind, action: action, modifiers: chord.modifiers, verb: verb ?? "the key", tokens[chord.end...], line: line, ctx: &ctx) else { return }
        if (112...115).contains(chord.key) {
            let word = KeyCodeMap.textWord(for: chord.key) ?? "f21"
            ctx.note(line, String(localized: "Line \(line): \(word) is not a key a Mac can send; it is kept as written."))
        }
        if chord.key == KeyCodeMap.globeFnCode {
            let shown = verb ?? "tap"
            ctx.note(line, String(localized: "Line \(line): \(shown) fn does nothing in a macro; fn works only beside a key in a row's output box."))
        }
        for prefix in chord.autoHotkeyPrefixes {
            let modifier = KeyCodeMap.textWord(for: modifierGlyphs[prefix] ?? 224) ?? "ctrl"
            let written = writeLine(ctx.steps.last ?? MacroStep(action: action), watches: ctx.watches)
            ctx.note(line, String(localized: "Line \(line): \(String(prefix)) read as \(modifier); InputConfig writes \(written)."))
        }
    }

    private struct Chord {
        var modifiers: [Int]
        var key: Int
        /// The index of the first token after the keys.
        var end: Int
        var autoHotkeyPrefixes: [Character]
    }

    /// Key words from the start of the tokens, the longest name first
    /// (`right cmd`, `page up`, `keyboard light down`), up to the first
    /// suffix word. Every key but the last must be a modifier.
    private static func parseChord(_ tokens: ArraySlice<Token>, verb: String?, line: Int, ctx: inout Context) -> Chord? {
        var codes: [Int] = []
        var words: [String] = []
        var prefixModifiers: [Int] = []
        var prefixes: [Character] = []
        var i = tokens.startIndex
        while i < tokens.endIndex {
            guard var word = tokens[i].word else {
                ctx.error(line, quotesMessage(tokens[i].quoted ?? "", line: line))
                return nil
            }
            if suffixStarters.contains(word) || repeatSuffix(word) != nil { break }
            // A glyph on its own, or AutoHotkey's ^ ! + and the glyphs in
            // front of a key: modifiers.
            if word.count == 1, let ch = word.first, !autoHotkeyPrefixes.contains(ch), let code = modifierGlyphs[ch] {
                prefixModifiers.append(code)
                i += 1
                continue
            }
            while word.count > 1, let ch = word.first, let code = modifierGlyphs[ch] {
                prefixModifiers.append(code)
                if autoHotkeyPrefixes.contains(ch), !prefixes.contains(ch) { prefixes.append(ch) }
                word.removeFirst()
            }
            // `key 2047`: a code the table has no name for.
            if word == "key", i + 1 < tokens.endIndex, let n = tokens[i + 1].word.flatMap({ Int($0) }), (0...0xFFFF).contains(n) {
                codes.append(n)
                words.append("key \(n)")
                i += 2
                continue
            }
            var matched = false
            for length in stride(from: longestKeyWord, through: 1, by: -1) where i + length <= tokens.endIndex {
                var parts = [word]
                var allWords = true
                for k in (i + 1)..<(i + length) {
                    guard let w = tokens[k].word else { allWords = false; break }
                    parts.append(w)
                }
                let name = parts.joined(separator: " ")
                guard allWords, let code = KeyCodeMap.code(forTextWord: name) else { continue }
                codes.append(code)
                words.append(name)
                i += length
                matched = true
                break
            }
            if !matched {
                if let suggestion = nearest(word, in: allKeyWords) {
                    ctx.error(line, String(localized: "Line \(line): no key called \(word). Did you mean \(suggestion)?"))
                } else {
                    ctx.error(line, String(localized: "Line \(line): no key called \(word)."))
                }
                return nil
            }
        }
        guard let key = codes.last else {
            let shown = verb ?? "tap"
            ctx.error(line, String(localized: "Line \(line): \(shown) needs a key: \(shown) shift."))
            return nil
        }
        // fn as the key with modifiers (the key picker's fn plus a modifier
        // toggle writes cmd fn) is kept with the note parseKeyStep adds;
        // fn ahead of another key cannot be held by a step.
        if codes.dropLast().contains(KeyCodeMap.globeFnCode) {
            ctx.error(line, String(localized: "Line \(line): fn works only in a row's output box, beside the key; a macro step cannot hold it."))
            return nil
        }
        var modifiers = prefixModifiers
        for (index, code) in codes.dropLast().enumerated() {
            guard modifierCodes.contains(code) else {
                let first = words[index], second = words[index + 1]
                ctx.error(line, String(localized: "Line \(line): \(first) and \(second) are two keys; write one key per line, with modifiers such as cmd first."))
                return nil
            }
            modifiers.append(code)
        }
        return Chord(modifiers: modifiers, key: key, end: i, autoHotkeyPrefixes: prefixes)
    }

    /// The suffixes of a key step, then the step. Returns false when the
    /// line had an error.
    @discardableResult
    private static func finishKeyStep(_ kind: MacroStepKind, action: OutputAction, modifiers: [Int], verb: String,
                                      _ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) -> Bool {
        guard let suffixes = parseSuffixes(tokens, verb: verb, line: line, ctx: &ctx),
              checkPressingSuffixes(suffixes, isKey: true, line: line, ctx: &ctx) else { return false }
        let all = sortedModifiers(modifiers + suffixes.modifiers)
        let step = MacroStep(action: action, delayMs: defaultMs, holdMs: suffixes.holdMs ?? defaultMs,
                             eventKind: kind == .tap ? nil : kind, modifiers: all.isEmpty ? nil : all).clamped()
        emit(step, times: suffixes.times, line: line, ctx: &ctx)
        return true
    }

    /// The suffixes of a click, text or System Function step, then the step.
    private static func finishPressingStep(_ kind: MacroStepKind, action: OutputAction, verb: String,
                                           _ tokens: ArraySlice<Token>, line: Int, ctx: inout Context) {
        guard let suffixes = parseSuffixes(tokens, verb: verb, line: line, ctx: &ctx),
              checkPressingSuffixes(suffixes, isKey: false, line: line, ctx: &ctx) else { return }
        let step = MacroStep(action: action, delayMs: defaultMs, holdMs: suffixes.holdMs ?? defaultMs,
                             eventKind: kind == .tap ? nil : kind).clamped()
        emit(step, times: suffixes.times, line: line, ctx: &ctx)
    }

    private static func parseJSONStep(_ kind: MacroStepKind, json: String, rest: String, line: Int, ctx: inout Context) {
        guard !json.isEmpty, let action = decodeStepJSON(json) else {
            ctx.error(line, jsonMessage(line))
            return
        }
        let stripped = stripComment(rest)
        if stripped.hadComment {
            ctx.commentLines += 1
            if ctx.firstCommentLine == 0 { ctx.firstCommentLine = line }
        }
        let tokenized = tokenize(stripped.code)
        if tokenized.unterminated {
            ctx.error(line, String(localized: "Line \(line): a quote is not closed; two quotes in a row stand for one."))
            return
        }
        guard let suffixes = parseSuffixes(tokenized.tokens[0...], verb: "step", line: line, ctx: &ctx),
              checkPressingSuffixes(suffixes, isKey: false, line: line, ctx: &ctx) else { return }
        var capped = action
        if capped.type == .typeText, let t = capped.text, t.count > Preset.importTextLimit {
            capped.text = String(t.prefix(Preset.importTextLimit))
            ctx.note(line, String(localized: "Line \(line): the text is cut at \(Preset.importTextLimit) characters."))
        }
        let step = MacroStep(action: capped, delayMs: defaultMs, holdMs: suffixes.holdMs ?? defaultMs,
                             eventKind: kind == .tap ? nil : kind).clamped()
        emit(step, times: suffixes.times, line: line, ctx: &ctx)
    }

    /// The suffixes a pressing step may carry: `for`, `x3`, and `with`
    /// only on a key.
    private static func checkPressingSuffixes(_ suffixes: Suffixes, isKey: Bool, line: Int, ctx: inout Context) -> Bool {
        if suffixes.hasWith, !isKey {
            ctx.error(line, withMessage(line))
            return false
        }
        if suffixes.glideMs != nil {
            ctx.error(line, String(localized: "Line \(line): over belongs to move to; for holds a key: tap space for 80."))
            return false
        }
        if suffixes.timeoutMs != nil || suffixes.continueOnTimeout != nil {
            ctx.error(line, waitForOnlyMessage(line))
            return false
        }
        return true
    }

    /// `for N`, `over N`, `x3`, `with cmd shift`, `up to N`, `then go on
    /// anyway` or `then skip the rest`, in any order after the step's own
    /// words. nil after an error.
    private static func parseSuffixes(_ tokens: ArraySlice<Token>, verb: String, line: Int, ctx: inout Context) -> Suffixes? {
        var suffixes = Suffixes()
        var i = tokens.startIndex
        while i < tokens.endIndex {
            guard let word = tokens[i].word else {
                ctx.error(line, String(localized: "Line \(line): could not read \"\(tokens[i].quoted ?? "")\" after \(verb)."))
                return nil
            }
            switch word {
            case "for":
                i += 1
                guard let ms = readMs(tokens.indices.contains(i) ? tokens[i] : nil, line: line,
                                      missing: String(localized: "Line \(line): for needs a time: tap space for 80."), ctx: &ctx) else { return nil }
                suffixes.holdMs = clampNoted(ms, MacroStep.waitRange, what: "hold", line: line, ctx: &ctx)
                i += 1
            case "over":
                i += 1
                guard let ms = readMs(tokens.indices.contains(i) ? tokens[i] : nil, line: line,
                                      missing: String(localized: "Line \(line): over needs a time: move to 640, 400 over 250."), ctx: &ctx) else { return nil }
                suffixes.glideMs = clampNoted(ms, MacroStep.waitRange, what: "glide", line: line, ctx: &ctx)
                i += 1
            case "with":
                suffixes.hasWith = true
                i += 1
                var any = false
                while i < tokens.endIndex, let w = tokens[i].word {
                    if w == "and" { i += 1; continue }
                    if w == "right", i + 1 < tokens.endIndex, let next = tokens[i + 1].word, let code = modifierCode("right " + next) {
                        suffixes.modifiers.append(code)
                        i += 2
                        any = true
                        continue
                    }
                    guard let code = modifierCode(w) else { break }
                    suffixes.modifiers.append(code)
                    i += 1
                    any = true
                }
                if !any {
                    ctx.error(line, String(localized: "Line \(line): with needs a modifier: cmd, opt, ctrl or shift."))
                    return nil
                }
            case "up" where i + 1 < tokens.endIndex && tokens[i + 1].word == "to":
                i += 2
                guard let ms = readMs(tokens.indices.contains(i) ? tokens[i] : nil, line: line,
                                      missing: String(localized: "Line \(line): up to needs a time: wait for \"Save dialog\" up to 5s."), ctx: &ctx) else { return nil }
                suffixes.timeoutMs = clampNoted(ms, MacroStep.timeoutRange, what: "timeout", line: line, ctx: &ctx)
                i += 1
            case "then":
                let rest = tokens[(i + 1)...].compactMap(\.word).joined(separator: " ")
                switch rest {
                case "go on anyway", "go on", "continue":
                    suffixes.continueOnTimeout = true
                case "skip the rest", "skip", "stop":
                    suffixes.continueOnTimeout = false
                default:
                    ctx.error(line, String(localized: "Line \(line): after then write go on anyway or skip the rest."))
                    return nil
                }
                i = tokens.endIndex
            default:
                if let n = repeatSuffix(word) {
                    suffixes.times = clampNoted(n, MacroStep.countRange, what: "x", line: line, ctx: &ctx)
                    i += 1
                } else {
                    ctx.error(line, String(localized: "Line \(line): could not read \(word) after \(verb)."))
                    return nil
                }
            }
        }
        return suffixes
    }

    /// A time from a token, with the line's error when it is missing or
    /// not a time. A European decimal without `s` gets its own message.
    private static func readMs(_ token: Token?, line: Int, missing: String, ctx: inout Context) -> Int? {
        guard let word = token?.word else {
            ctx.error(line, missing)
            return nil
        }
        if let ms = parseDuration(word) { return ms }
        let bare = word.hasSuffix("ms") ? String(word.dropLast(2)) : word
        if isCommaDecimal(bare) {
            ctx.error(line, commaMessage(line))
        } else {
            ctx.error(line, missing)
        }
        return nil
    }

    /// The value in range, with a note when it had to move.
    private static func clampNoted(_ value: Int, _ range: ClosedRange<Int>, what: String, line: Int, ctx: inout Context) -> Int {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if clamped != value {
            let low = range.lowerBound, high = range.upperBound
            ctx.note(line, String(localized: "Line \(line): \(what) is \(low) to \(high); \(value) was read as \(clamped)."))
        }
        return clamped
    }

    /// Whether a word can start a key's name (or carries a modifier glyph).
    private static func isKeyStart(_ word: String) -> Bool {
        if keyFirstWords.contains(word) { return true }
        guard let first = word.first else { return false }
        return modifierGlyphs[first] != nil && (word.count > 1 || !autoHotkeyPrefixes.contains(first))
    }

    /// `click`, `right click`, `middle click`, `left click` or `mouse N`
    /// at the start of the tokens.
    private static func clickWords(_ tokens: ArraySlice<Token>) -> (verb: String, args: [String], end: Int)? {
        guard let first = tokens.first?.word else { return nil }
        let second = tokens.count > 1 ? tokens[tokens.startIndex + 1].word : nil
        switch first {
        case "click":
            return ("click", [], tokens.startIndex + 1)
        case "right", "middle", "left":
            guard second == "click" else { return nil }
            return ("\(first) click", [], tokens.startIndex + 2)
        case "mouse":
            guard let second else { return nil }
            return ("mouse", [second], tokens.startIndex + 2)
        default:
            return nil
        }
    }

    /// Whether what follows a System Function's words can belong to it: the
    /// end of the line, its quoted parameter or a suffix. A bare `launchpad
    /// key` or `spotlight key` is the key instead.
    private static func endsSystemWords(_ rest: ArraySlice<Token>) -> Bool {
        guard let first = rest.first else { return true }
        guard let word = first.word else { return true }
        return suffixStarters.contains(word) || repeatSuffix(word) != nil
    }

    /// Whether a key's name starts with a System Function's words, so a
    /// bare line of it would read as the function.
    private static func startsWithSystemWord(_ keyWords: String) -> Bool {
        let words = keyWords.split(separator: " ").map { Token.word(String($0)) }
        return systemWords(words[0...]) != nil
    }

    /// A System Function's words at the start of the tokens, the longest
    /// name first.
    private static func systemWords(_ tokens: ArraySlice<Token>) -> (word: String, kind: SystemActionKind, end: Int)? {
        for length in stride(from: 3, through: 1, by: -1) where tokens.startIndex + length <= tokens.endIndex {
            let words = tokens[tokens.startIndex..<(tokens.startIndex + length)].compactMap(\.word)
            guard words.count == length else { continue }
            let phrase = words.joined(separator: " ")
            if let kind = OutputAction.macroTextSystemKind(forWord: phrase) {
                return (phrase, kind, tokens.startIndex + length)
            }
        }
        return nil
    }

    // MARK: Messages used more than once

    private static func quotesMessage(_ quoted: String, line: Int) -> String {
        String(localized: "Line \(line): quotes mean text. Write tap \(quoted) for the key or type \"\(quoted)\" for the word.")
    }

    private static func withMessage(_ line: Int) -> String {
        String(localized: "Line \(line): with belongs on a key step; type and system functions have no modifiers.")
    }

    private static func waitForOnlyMessage(_ line: Int) -> String {
        String(localized: "Line \(line): up to and then belong to wait for.")
    }

    private static func waitMessage(_ line: Int) -> String {
        String(localized: "Line \(line): wait needs a time: wait 300.")
    }

    private static func waitForMessage(_ line: Int) -> String {
        String(localized: "Line \(line): wait for needs a watch's name in quotes, or its number: wait for \"Save dialog\" or wait for #1.")
    }

    private static func moveMessage(_ line: Int) -> String {
        String(localized: "Line \(line): move to takes two whole numbers: move to 640, 400.")
    }

    private static func jsonMessage(_ line: Int) -> String {
        String(localized: "Line \(line): step needs one output's JSON, as the app wrote it.")
    }

    private static func commaMessage(_ line: Int) -> String {
        String(localized: "Line \(line): write seconds with a point: 1.5s.")
    }
}
