import Foundation

/// What the macro recorder saw: every key and mouse button going down or
/// up, with the moment it happened, and the macro steps that play it back.
///
/// The conversion is pure so the Test Bench can check it. A key pressed
/// and released on its own is a Tap step with the hold the recording
/// measured. A key still down when another goes down becomes a Hold down
/// step and a later Release step, so chords play back as chords. A
/// modifier (Shift, Control, Option, Command) held over a whole tap of
/// another key is not a step of its own: it rides on that tap as its
/// shortcut modifier, the way the editor's modifier toggles store it.
struct MacroRecording: Equatable {
    enum Control: Hashable {
        /// A key, by its HID usage code (the code the rest of the app stores).
        case key(Int)
        /// A mouse button: 0 left, 1 right, 2 middle, then the side buttons.
        case mouseButton(Int)
        /// Scrolling: lines on an axis, signed as CoreGraphics reports them
        /// (positive is up on the vertical axis, left on the horizontal).
        /// An instant: it has no release.
        case scroll(axis: MouseAxis, lines: Int)
        /// The pointer at a point, CoreGraphics coordinates. An instant.
        case move(x: Double, y: Double)

        var action: OutputAction {
            switch self {
            case .key(let code): return OutputAction(type: .key, keyCode: code)
            case .mouseButton(let button): return OutputAction(type: .mouseButton, mouseButtonIndex: button)
            case .scroll(let axis, let lines):
                var a = OutputAction(type: .mouseWheelStep)
                a.mouseAxis = axis
                // The sign scrollWheelStep posts back: .positive is +N in the
                // same field the tap read, so a replay is what the app saw.
                a.mouseDirection = lines > 0 ? .positive : .negative
                return a
            case .move(let x, let y):
                var a = OutputAction(type: .mouseMotion)
                a.clickX = x; a.clickY = y
                return a
            }
        }

        var isModifier: Bool {
            if case .key(let code) = self { return MacroRecording.modifierCodes.contains(code) }
            return false
        }

        /// Scrolls and moves happen; they are not held.
        var isInstant: Bool {
            switch self {
            case .scroll, .move: return true
            default: return false
            }
        }
    }

    struct Edge: Equatable {
        var control: Control
        var down: Bool
        /// Seconds on a monotonic clock (`ProcessInfo.systemUptime`).
        var at: Double
    }

    private(set) var edges: [Edge] = []

    /// Left and right Control, Shift, Option and Command.
    static let modifierCodes: Set<Int> = [224, 225, 226, 227, 228, 229, 230, 231]
    /// More steps than this and the recording is cut, not the macro's
    /// own limit (it has none) but a bound on what one press can play.
    static let maxSteps = 200
    /// The default a step gets when the recorded timing is not wanted.
    static let evenMs = 50

    var isEmpty: Bool { edges.isEmpty }

    mutating func add(_ control: Control, down: Bool, at: Double) {
        edges.append(Edge(control: control, down: down, at: at))
    }

    mutating func removeAll() { edges.removeAll() }

    /// Presses still down as a take ends (fn let go after fn F12 stopped
    /// it, a release made while InputConfig was in front). One with nothing
    /// recorded after it is dropped; one held over later steps is let go at
    /// a hair after the last of them, so a trailing scroll stays inside it.
    /// Left open, a release in the next take made it one span over
    /// everything between: a modifier held across the macro. Each control
    /// is judged against the edges as they stand now, so the order a set
    /// hands them out, which differs per launch, changes nothing.
    mutating func closeOpen(_ controls: Set<Control>) {
        var dropped = IndexSet()
        var closing: [Control] = []
        for c in controls {
            guard let i = edges.lastIndex(where: { $0.control == c && $0.down }) else { continue }
            if edges[(i + 1)...].allSatisfy({ controls.contains($0.control) && $0.down }) {
                dropped.insert(i)
            } else {
                closing.append(c)
            }
        }
        for i in dropped.reversed() { edges.remove(at: i) }
        guard let last = edges.last?.at else { return }
        for c in closing.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            edges.append(Edge(control: c, down: false, at: last + 0.001))
        }
    }

    /// Drops the Escape key edges at the end from `since` on (the double
    /// Escape that stopped the recording), with any pointer path or scroll
    /// recorded between them, and nothing else: an Escape pressed earlier,
    /// outside the double press window, stays a step.
    mutating func dropTrailingEscapes(since: Double = -1) {
        while let last = edges.last, last.at >= since {
            switch last.control {
            case .key(41), .move, .scroll: edges.removeLast()
            default: return
            }
        }
    }

    /// Drops the moves at the end: the pointer's trip to the panel's Pause.
    mutating func dropTrailingMoves() {
        while let last = edges.last, case .move = last.control { edges.removeLast() }
    }

    /// Drops a left button press and release at the very end, both within
    /// `within` seconds before `before`, and any move recorded with it:
    /// the click that brought InputConfig to the front. True when one went.
    @discardableResult
    mutating func dropTrailingClick(before: Double, within: Double) -> Bool {
        guard let up = edges.last, case .mouseButton(0) = up.control, !up.down, before - up.at <= within,
              let downIndex = edges.lastIndex(where: { if case .mouseButton(0) = $0.control { return $0.down }; return false }),
              before - edges[downIndex].at <= within else { return false }
        edges.removeSubrange(downIndex...)
        while let last = edges.last, case .move = last.control { edges.removeLast() }
        return true
    }

    /// Drops what brought InputConfig back to the front at the end of a
    /// take: trailing moves, a mouse button still down, and a Command Tab
    /// (Tab edges inside a Command press, nothing else after it). steps()
    /// already ignores these at the end, but Record More appends after
    /// them, so they are cut from the edges here. Returns the presses
    /// removed, for the sheet's count.
    @discardableResult
    mutating func dropReturnToApp() -> Int {
        func isCommand(_ c: Control) -> Bool { if case .key(let k) = c { return k == 227 || k == 231 }; return false }
        func isTab(_ c: Control) -> Bool { if case .key(43) = c { return true }; return false }
        var presses = 0
        var changed = true
        while changed {
            changed = false
            while let last = edges.last, case .move = last.control { edges.removeLast(); changed = true }
            if let last = edges.last, case .mouseButton = last.control, last.down {
                edges.removeLast(); presses += 1; changed = true
            }
            if let c = edges.lastIndex(where: { isCommand($0.control) && $0.down }) {
                let tail = edges[(c + 1)...]
                if tail.allSatisfy({ isTab($0.control) || isCommand($0.control) }),
                   tail.contains(where: { isTab($0.control) && $0.down }) {
                    presses += edges[c...].filter { $0.down && !$0.control.isInstant }.count
                    edges.removeSubrange(c...)
                    changed = true
                }
            }
        }
        return presses
    }

    /// Seconds from the first edge to the last.
    var duration: Double {
        guard let first = edges.first?.at, let last = edges.last?.at else { return 0 }
        return max(0, last - first)
    }

    // MARK: - Steps

    /// One control pressed then released.
    private struct Span {
        var control: Control
        var down: Double
        var up: Double
        var modifiers: [Int] = []
    }

    /// The press and release pairs, in press order. A release with no
    /// press before it is noise. A press with no release by the end of the
    /// recording is dropped: it is the click or the key that brought
    /// InputConfig back to the front, not part of the macro.
    private var spans: [Span] {
        var open: [Control: Double] = [:]
        var out: [Span] = []
        for edge in edges {
            if edge.control.isInstant {
                if edge.down { out.append(Span(control: edge.control, down: edge.at, up: edge.at)) }
                continue
            }
            if edge.down {
                // A second down for a key still down (a repeat the monitor
                // let through) keeps the first press time.
                if open[edge.control] == nil { open[edge.control] = edge.at }
            } else if let start = open.removeValue(forKey: edge.control) {
                out.append(Span(control: edge.control, down: start, up: max(start, edge.at)))
            }
        }
        return out.sorted { $0.down < $1.down }
    }

    /// Scrolls the same way within this long of each other are one step.
    static let scrollMergeSeconds = 0.15
    /// Path samples arrive at least 0.1 s apart while the pointer moves; a
    /// longer gap between two moves is a pause, not a glide.
    static let maxGlideSeconds = 0.5

    /// A wait longer than this is cut to it when `capWaitMs` asks: a pause
    /// to read a dialog is not part of the macro.
    static let cappedWaitMs = 1000

    /// The steps that play the recording back. `keepTiming` keeps the
    /// waits and holds as recorded, rounded to the millisecond; otherwise
    /// every step gets the editor's usual 50 ms. `capWaitMs` is the longest
    /// wait kept before a step (nil keeps them all); holds are never cut.
    func steps(keepTiming: Bool = true, capWaitMs: Int? = nil) -> [MacroStep] {
        var all = spans
        // Consecutive scrolls the same way merge into one step of more lines.
        var merged: [Span] = []
        for span in all {
            if case .scroll(let axis, let lines) = span.control, let last = merged.last,
               case .scroll(let lastAxis, let lastLines) = last.control,
               axis == lastAxis, (lines > 0) == (lastLines > 0), span.down - last.up <= Self.scrollMergeSeconds {
                merged[merged.count - 1].control = .scroll(axis: axis, lines: lastLines + lines)
                merged[merged.count - 1].up = span.up
            } else {
                merged.append(span)
            }
        }
        all = merged
        // A modifier down when another key goes down becomes that key's
        // shortcut modifier and no step of its own (macOS reads a shortcut
        // at the key's down, so the modifier may let go during the hold).
        // Keys only: a mouse click keeps the modifier as its own Hold down
        // and Release, which the click then goes out under. A modifier that
        // covers no key down (Shift pressed alone) is an ordinary key.
        // A modifier that also covers a click is not folded: it stays its
        // own Hold down and Release around everything it covered, keys
        // included, so the click keeps it.
        var folded = Set<Int>()
        for (i, span) in all.enumerated() where span.control.isModifier {
            guard case .key(let code) = span.control else { continue }
            let covers = all.indices.filter { j in
                j != i && !all[j].control.isModifier && !all[j].control.isInstant
                    && all[j].down >= span.down && all[j].down <= span.up
            }
            let coversClick = covers.contains { if case .mouseButton = all[$0].control { return true }; return false }
            // A scroll under the modifier needs it held too (Command scroll
            // zooms, Shift scroll goes sideways), and a scroll step carries
            // no modifiers of its own, so the modifier stays a Hold down.
            let coversScroll = all.indices.contains { j in
                if case .scroll = all[j].control { return all[j].down >= span.down && all[j].down <= span.up }
                return false
            }
            // A key still held when something else goes down after the
            // modifier was let go plays as a Hold down: folded, the modifier
            // stayed on for the next keys too, and a rolled "Th" played "TH".
            let outlives = covers.contains { j in
                all.indices.contains { k in
                    k != i && k != j && !all[k].control.isModifier
                        && all[k].down > span.up && all[k].down < all[j].up
                }
            }
            if covers.isEmpty || coversClick || coversScroll || outlives { continue }
            for j in covers { all[j].modifiers.append(code) }
            folded.insert(i)
        }
        let regular = all.indices.filter { !folded.contains($0) }.map { all[$0] }
        // Trailing Command Tab is the switch back to InputConfig, not a
        // step, and a move nothing follows is the pointer going to the
        // InputConfig window (or the Dock) to stop the recording. The two
        // can interleave (a nudge while the switcher is up), so both strip
        // until neither removes anything.
        var kept = regular
        while true {
            let before = kept.count
            while let last = kept.last, case .move = last.control { kept.removeLast() }
            while let last = kept.last, case .key(43) = last.control,
                  last.modifiers.contains(where: { $0 == 227 || $0 == 231 }) {
                kept.removeLast()
            }
            if kept.count == before { break }
        }

        // A span nothing else happens inside is a Tap; one another press
        // starts or ends inside is a Hold down and a later Release, so
        // rolling chords (W then D while steering) let go in the recorded
        // order. A scroll or a move inside a press splits it the same way,
        // so the scroll plays with the key held and a drag is a drag.
        enum Phase { case tap(hold: Double), down, up, instant }
        var timeline: [(at: Double, phase: Phase, span: Span)] = []
        for (i, span) in kept.enumerated() {
            if span.control.isInstant { timeline.append((span.down, .instant, span)); continue }
            let interrupted = kept.indices.contains { j in
                j != i
                    && ((kept[j].down > span.down && kept[j].down < span.up)
                        || (kept[j].up > span.down && kept[j].up < span.up))
            }
            if interrupted {
                timeline.append((span.down, .down, span))
                timeline.append((span.up, .up, span))
            } else {
                timeline.append((span.down, .tap(hold: span.up - span.down), span))
            }
        }
        // Releases first at an equal instant, so a chord lets go before
        // the next press.
        timeline.sort { a, b in
            if a.at != b.at { return a.at < b.at }
            if case .up = a.phase { return true }
            return false
        }
        // Over the cap, the path's mid-glide samples go first (a move right
        // before anything but another move stays), so presses are not cut.
        // One pass: the entries that could go are the moves followed by a
        // move, and dropping the last of them never changes which earlier
        // ones qualify, so the last `excess` of them go together. The loop
        // this replaces rescanned the whole timeline per removal, which with
        // the pointer path on made every recorded edge cost the square of
        // the take.
        if timeline.count > Self.maxSteps {
            var candidates: [Int] = []
            for k in timeline.indices where k + 1 < timeline.count {
                if case .move = timeline[k].span.control, case .move = timeline[k + 1].span.control {
                    candidates.append(k)
                }
            }
            let drop = Set(candidates.suffix(timeline.count - Self.maxSteps))
            if !drop.isEmpty {
                timeline = timeline.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            }
        }

        var out: [MacroStep] = []
        var cursor = timeline.first?.at ?? 0
        // While a Hold down is outstanding the time passing is hold, not
        // pause, so the wait cap stays out of it.
        var held = 0
        for (n, item) in timeline.prefix(Self.maxSteps).enumerated() {
            var wait = keepTiming ? Self.ms(item.at - cursor) : Self.evenMs
            if let capWaitMs, held == 0 { wait = min(wait, capWaitMs) }
            let modifiers = item.span.modifiers.isEmpty ? nil : Array(Set(item.span.modifiers)).sorted()
            switch item.phase {
            case .instant:
                var glide = 0
                switch item.span.control {
                case .scroll(_, let lines):
                    out.append(MacroStep(action: item.span.control.action, delayMs: wait, holdMs: 0,
                                         eventKind: nil, modifiers: nil, count: min(100, max(1, abs(lines)))))
                case .move:
                    // A move glides until the next move when the path was
                    // recorded; one right before a click is a jump. Samples
                    // come at least 0.1 s apart while the pointer moves, so
                    // a longer gap is the pointer standing still: a jump,
                    // and the pause goes into the next step's wait, where
                    // the cap applies.
                    if keepTiming, n + 1 < timeline.count, case .move = timeline[n + 1].span.control {
                        let gap = timeline[n + 1].at - item.at
                        if gap <= Self.maxGlideSeconds { glide = Self.ms(gap) }
                    }
                    out.append(MacroStep(action: item.span.control.action, delayMs: wait, holdMs: glide, eventKind: .moveTo))
                default:
                    break
                }
                // The glide is time spent, so the next step does not wait
                // for it again.
                cursor = item.at + Double(glide) / 1000
            case .tap(let hold):
                out.append(MacroStep(action: item.span.control.action, delayMs: wait,
                                     holdMs: keepTiming ? max(1, Self.ms(hold)) : Self.evenMs,
                                     eventKind: nil, modifiers: modifiers))
                cursor = keepTiming ? item.at + hold : item.at
            case .down:
                out.append(MacroStep(action: item.span.control.action, delayMs: wait, holdMs: 0,
                                     eventKind: .down, modifiers: modifiers))
                cursor = item.at
                held += 1
            case .up:
                out.append(MacroStep(action: item.span.control.action, delayMs: wait, holdMs: 0,
                                     eventKind: .up, modifiers: modifiers))
                cursor = item.at
                held = max(0, held - 1)
            }
        }
        return out
    }

    /// Whole milliseconds, never negative; the engine clamps at 30 s.
    static func ms(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 30) * 1000 + 0.5)
    }
}
