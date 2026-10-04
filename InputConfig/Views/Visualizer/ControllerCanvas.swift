import SwiftUI

/// Draws one controller model as you hold it: its outline, every control at
/// its real place with its printed legend, live state on each, and the
/// function each control is bound to in this preset beneath it. Bumpers and
/// triggers sit on a strip above the front, paddles and back buttons on a
/// strip below it, drawn as held (the player's left on the left).
struct ControllerCanvas: View {
    let layout: ControllerLayout
    var variant: String? = nil
    /// The live reading for the slot.
    let state: ControllerState
    /// What a control shows: printed text or a symbol.
    let legend: (PlacedControl) -> (text: String?, symbol: String?)
    /// What a control shows under its own model's names, so its printed
    /// color is dropped when the legend shows another family's name.
    var ownLegend: ((PlacedControl) -> (text: String?, symbol: String?))? = nil
    /// The function a control is bound to here, for its caption.
    let caption: (PlacedControl) -> String?
    /// Finger positions (0...1, y down) on a touch surface, when the pad
    /// reports them through the touch service rather than as axes.
    var touchPoints: (Int) -> [CGPoint] = { _ in [] }
    /// Surfaces whose fingers come only from `touchPoints` (the touch
    /// service, not ControllerState): their dots redraw on their own clock,
    /// since a finger moving changes nothing else the canvas reads.
    var liveTouchSurfaces: Set<Int> = []
    /// The preset's touchpad zones, drawn on the main touch surface, and
    /// whether one is pressed now.
    var zones: [TouchpadRegion] = []
    var zoneOn: (UUID) -> Bool = { _ in false }
    /// A control's spoken and inspector name; nil uses its legend.
    var name: ((PlacedControl) -> String)? = nil
    /// Stops the live finger clock (the app is in the background).
    var livePaused = false
    /// The preset's light bar color, for a light control.
    var lightColor: Color? = nil
    /// Where an analog axis starts to count (the row's deadzone), marked
    /// on triggers and pedals as in 1.5; nil draws no mark.
    var threshold: (Int) -> Float? = { _ in nil }
    /// The deadzones this panel's rows set on a control, marked the way the
    /// deadzone calibration sheet marks them; nil draws none.
    var deadzone: (PlacedControl) -> CanvasDeadzone? = { _ in nil }
    var showCaptions = true
    /// A view drawn midway between two controls (the gyro ball between a
    /// DualSense's triggers), by the controls' ids; nil draws nothing.
    var between: (first: String, second: String, view: AnyView)? = nil
    /// Wraps a control so a click opens its inspector.
    let inspect: (PlacedControl, AnyView) -> AnyView

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.visualizerSuspended) private var suspended

    /// What VoiceOver calls a control.
    private func spoken(_ c: PlacedControl, _ fallback: String) -> String {
        name?(c) ?? c.name ?? legend(c).text ?? fallback
    }

    private var hasTop: Bool { layout.hasTop(variant: variant) }
    private var hasBack: Bool { layout.hasBack(variant: variant) }
    private let gap: CGFloat = 0.03       // between bands, as a fraction of width
    private let pad: CGFloat = 0.018      // above and below a band's controls
    private let backLabel: CGFloat = 0.03 // the "Back, as you hold it" line
    /// Each key column, as a fraction of the width, and the gap between it
    /// and the drawing.
    /// The key column's width when measuring (the typical one), and the
    /// widest it gets: a longer caption wraps to a second line instead, so
    /// the drawing keeps its size.
    private let referenceKey: CGFloat = 0.19
    private let maxKey: CGFloat = 0.22
    private let keyGap: CGFloat = 0.03
    /// Extra height under the drawing when there is a key, so a line can
    /// reach a low control from below.
    private let keyRoom: CGFloat = 0.035

    /// What is drawn: every control but ports and controls that send
    /// nothing, which without the body around them read as noise.
    private func drawn(_ face: LayoutFace) -> [PlacedControl] {
        // A model the Mac reads nothing from (the Joy-Con 2 pair) is still
        // drawn whole, dimmed, rather than as an empty panel.
        let readsNothing = layout.controls.allSatisfy { c in
            if case .notReported = c.readable { return true }
            return c.kind == .port || c.kind == .light
        }
        return layout.controls(on: face, variant: variant).filter { c in
            if case .notReported = c.readable { return readsNothing && c.kind != .port }
            return c.kind != .port
        }
    }

    /// One band of the drawing (the top edge, the face, the back), fitted
    /// to the controls it draws: its height is only the span they cover.
    private struct Band {
        let face: LayoutFace
        let controls: [PlacedControl]
        /// The face's full height over the canvas width, as the layout was
        /// drawn (its coordinates are fractions of it).
        let nominal: CGFloat
        /// Horizontal placement, as fractions of the canvas width.
        let x0: CGFloat, width: CGFloat
        /// Control sizes scale with a narrower band.
        let scale: CGFloat
        let ymin: CGFloat, ymax: CGFloat
        /// The whole drawing's zoom and left edge, so the controls fill the
        /// width at their true relative places (see `bands`).
        var zoom: CGFloat = 1
        var shift: CGFloat = 0
        var height: CGFloat { max(0, ymax - ymin) * nominal * zoom }
    }

    /// The reference drawing the key is measured against: every caption
    /// test and the crowded pills use it, so none depends on the key's
    /// final width.
    private var referenceBands: [Band] { bands(margin: referenceKey + keyGap) }

    private func bands(margin: CGFloat) -> [Band] {
        func band(_ face: LayoutFace, nominal: CGFloat, x0: CGFloat, width: CGFloat, scale: CGFloat) -> Band? {
            let list = drawn(face)
            guard !list.isEmpty, nominal > 0 else { return nil }
            var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
            for c in list {
                // Half the control's height, as a fraction of the face.
                let half = (c.height ?? c.size) * scale / 2 / nominal
                lo = min(lo, c.center.y - half); hi = max(hi, c.center.y + half)
            }
            return Band(face: face, controls: list, nominal: nominal, x0: x0, width: width, scale: scale, ymin: lo, ymax: hi)
        }
        let backScale: CGFloat = 0.6 / 0.76
        var list = [
            hasTop ? band(.top, nominal: layout.topStrip, x0: 0, width: 1, scale: 1) : nil,
            band(.front, nominal: 1 / layout.aspect, x0: 0, width: 1, scale: 1),
            hasBack ? band(.back, nominal: layout.backStrip * backScale, x0: 0.2, width: 0.6, scale: backScale) : nil,
        ].compactMap { $0 }
        // One zoom for the whole drawing: the span the controls cover, left
        // to right, widened to the canvas (with room for side captions), so
        // a layout drawn to true scale on a wide body keeps every control at
        // its real place relative to the others, at a readable size.
        // Each control's half width as drawn: a capsule set at an angle by
        // its turned box, and a pill (once the zoom is roughly known) by its
        // word, at a typical panel width.
        func span(zoom: CGFloat?) -> (CGFloat, CGFloat) {
            var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
            for b in list {
                for c in b.controls {
                    var half = c.size * b.scale / 2
                    if case .capsule(let angle) = c.shape, angle != 0 {
                        let r = angle * .pi / 180, h = (c.height ?? c.size) * b.scale
                        half = (abs(c.size * b.scale * cos(r)) + abs(h * sin(r))) / 2
                    }
                    if let zoom, zoom > 0, let word = wordFor(c) {
                        let px = CaptionLayout.measure(word, fontSize: pillFontSize(560)) + 10
                        half = max(half, px / 560 / zoom / 2)
                    }
                    let x = b.x0 + c.center.x * b.width
                    lo = min(lo, x - half); hi = max(hi, x + half)
                }
            }
            return (lo, hi)
        }
        var (lo, hi) = span(zoom: nil)
        guard hi > lo else { return list }
        (lo, hi) = span(zoom: min(1.8, (1 - 2 * margin) / (hi - lo)))
        // Between the key columns when there is a key, else nearly the
        // whole width.
        let zoom = min(1.8, (1 - 2 * margin) / (hi - lo))
        let shift = 0.5 - (lo + hi) / 2 * zoom
        for i in list.indices { list[i].zoom = zoom; list[i].shift = shift }
        return list
    }

    /// Each band's top edge, as a fraction of the width, and the total.
    private func stack(_ bands: [Band], inset: CGFloat = 0) -> (tops: [CGFloat], total: CGFloat) {
        var y: CGFloat = inset
        var tops: [CGFloat] = []
        for (n, b) in bands.enumerated() {
            if n > 0 { y += gap }
            if b.face == .back { y += backLabel }
            tops.append(y)
            y += b.height + 2 * pad
        }
        return (tops, y)
    }

    /// The drawing's layout for one pass: whether there is a key, its column
    /// width, the bands, where they sit, and the height over the width. The
    /// view and the checks in KeyLayoutTests both use it.
    private struct Metrics {
        let keyed: Bool
        let kf: CGFloat
        let bands: [Band]
        let tops: [CGFloat]
        let total: CGFloat
    }

    private var metrics: Metrics {
        let keyed = keyOn
        let kf = keyed ? keyFraction : 0
        let bands = bands(margin: keyed ? kf + keyGap : 0.1)
        // Room above the drawing too, so a line can reach a control on the
        // top edge from above.
        let laid = stack(bands, inset: keyed ? topInset : 0)
        // Tall enough for the longer key column, counting two-line captions.
        let estimate = keyed ? keyEntries(bands: bands, tops: laid.tops, width: 560, height: .greatestFiniteMagnitude, key: kf, anchors: false) : []
        let perSide = max(estimate.filter { $0.left }.reduce(0) { $0 + $1.lines }, estimate.filter { !$0.left }.reduce(0) { $0 + $1.lines })
        let total = keyed ? max(laid.total + keyRoom, CGFloat(perSide) * 0.028 + 0.02) : laid.total
        return Metrics(keyed: keyed, kf: kf, bands: bands, tops: laid.tops, total: total)
    }

    var body: some View {
        // Worked out once per drawing pass.
        let m = metrics
        let keyed = m.keyed, kf = m.kf, bands = m.bands
        let laid = (tops: m.tops, total: m.total)
        let total = m.total
        GeometryReader { geo in
            let w = geo.size.width
            let entries = keyed ? keyEntries(bands: bands, tops: laid.tops, width: w, height: geo.size.height, key: kf) : []
            ZStack(alignment: .topLeading) {
                // Leader lines first, so the controls sit on top of them.
                if !entries.isEmpty { leaderLines(entries, key: kf) }
                ForEach(Array(bands.enumerated()), id: \.offset) { n, b in
                    if b.face == .back {
                        Text("Back, as you hold it")
                            .font(.caption2)
                            .foregroundStyle(.hint)
                            .position(x: w / 2, y: (laid.tops[n] - backLabel / 2) * w)
                    }
                    ForEach(b.controls) { control in
                        let frame = controlFrame(control, band: b, top: laid.tops[n], width: w)
                        controlView(control, size: frame.size)
                            // What it does here, and its deadzone, for
                            // VoiceOver (the key entry is hidden from
                            // accessibility).
                            .accessibilityHint([caption(control), deadzone(control)?.help]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". "))
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                ForEach(entries) { e in keyLabel(e, width: w, key: kf) }
                if let between, let mid = midpoint(between.first, between.second, bands: bands, tops: laid.tops, width: w) {
                    between.view.position(x: mid.x, y: mid.y)
                }
            }
        }
        .aspectRatio(1 / max(0.1, total), contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(layout.displayName)
    }

    /// The point midway between two drawn controls' centers.
    private func midpoint(_ a: String, _ b: String, bands: [Band], tops: [CGFloat], width w: CGFloat) -> CGPoint? {
        var found: [CGPoint] = []
        for (n, band) in bands.enumerated() {
            for c in band.controls where c.id == a || c.id == b {
                let f = controlFrame(c, band: band, top: tops[n], width: w)
                found.append(CGPoint(x: f.midX, y: f.midY))
            }
        }
        guard found.count == 2 else { return nil }
        return CGPoint(x: (found[0].x + found[1].x) / 2, y: (found[0].y + found[1].y) / 2)
    }

    private func controlFrame(_ c: PlacedControl, band b: Band, top: CGFloat, width w: CGFloat) -> CGRect {
        let raw = rawFrame(c, band: b, top: top, width: w)
        // A button named in words, as in 1.5, is a pill as wide as its name.
        guard let word = pillWord(c) else { return raw }
        return pillFrame(raw, word: word, width: w)
    }

    /// The control at its true size and place.
    private func rawFrame(_ c: PlacedControl, band b: Band, top: CGFloat, width w: CGFloat) -> CGRect {
        let cw = c.size * w * b.scale * b.zoom
        let ch = (c.height ?? c.size) * w * b.scale * b.zoom
        let x = (b.shift + (b.x0 + c.center.x * b.width) * b.zoom) * w
        let y = (top + pad + (c.center.y - b.ymin) * b.nominal * b.zoom) * w
        return CGRect(x: x - cw / 2, y: y - ch / 2, width: cw, height: ch)
    }

    private func pillFrame(_ raw: CGRect, word: String, width w: CGFloat) -> CGRect {
        let size = pillFontSize(w)
        let ch = size + 7
        let cw = max(raw.width, CaptionLayout.measure(word, fontSize: size) + 10, ch)
        return CGRect(x: raw.midX - cw / 2, y: raw.midY - ch / 2, width: cw, height: ch)
    }

    /// Pills that, as wide as their word, would run into a neighbor (two
    /// small buttons side by side on a grip, Create beside the DualSense's
    /// light bar): drawn at their true size with the name in the key
    /// instead. Worked out once per drawing, at the narrowest drawing a key
    /// can leave (the widest columns), so a pill that fits there fits with
    /// any captions.
    private var crowdedPills: Set<String> {
        let cacheKey = "\(layout.id.rawValue)|\(variant ?? "")"
        if let hit = Self.crowdedCache[cacheKey] { return hit }
        let w: CGFloat = 560
        let keyed = bands(margin: maxKey + keyGap), laid = stack(keyed)
        var frames: [(id: String, frame: CGRect, pill: Bool)] = []
        for (n, b) in keyed.enumerated() {
            for c in b.controls {
                let raw = rawFrame(c, band: b, top: laid.tops[n], width: w)
                if let word = wordFor(c) { frames.append((c.id, pillFrame(raw, word: word, width: w), true)) }
                else { frames.append((c.id, Self.drawnBounds(c, raw), false)) }
            }
        }
        var crowded = Set<String>()
        for f in frames where f.pill {
            if frames.contains(where: { $0.id != f.id && !$0.frame.contains(f.frame) && $0.frame.insetBy(dx: -1, dy: -1).intersects(f.frame) }) {
                crowded.insert(f.id)
            }
        }
        Self.crowdedCache[cacheKey] = crowded
        return crowded
    }

    nonisolated(unsafe) private static var crowdedCache: [String: Set<String>] = [:]

    /// What a control covers when drawn: a capsule set at an angle reaches
    /// past its frame, so its turned bounding box.
    static func drawnBounds(_ c: PlacedControl, _ frame: CGRect) -> CGRect {
        guard case .capsule(let angle) = c.shape, angle != 0 else { return frame }
        let r = angle * .pi / 180
        let w = abs(frame.width * cos(r)) + abs(frame.height * sin(r))
        let h = abs(frame.width * sin(r)) + abs(frame.height * cos(r))
        return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
    }

    private func pillFontSize(_ w: CGFloat) -> CGFloat { max(7.5, min(10, w * 0.0145)) }

    /// Glyphs kept as glyphs: the PlayStation face shapes and arrows. Every
    /// other icon (Options, Home, Create, Capture, View, Star) is written as
    /// its name, the way the 1.5 visualizer labeled them.
    private static let keptSymbols: Set<String> = [
        "xmark", "circle", "triangle", "square", "square.fill",
        "arrowtriangle.up.fill", "arrowtriangle.down.fill", "arrowtriangle.left.fill", "arrowtriangle.right.fill",
        "chevron.up", "chevron.down", "arrow.clockwise", "arrow.counterclockwise",
    ]

    /// What a button shows inside: a crowded pill's word in place of its
    /// icon, else its legend.
    private func shownLegend(_ c: PlacedControl) -> (text: String?, symbol: String?) {
        if let word = wordFor(c) { return (word, nil) }
        return legend(c)
    }

    /// The word a symbol button is drawn with, unless it has no room.
    private func pillWord(_ c: PlacedControl) -> String? {
        guard let word = wordFor(c), !crowdedPills.contains(c.id) else { return nil }
        return word
    }

    /// The word a symbol button is written with, or nil to draw it as is.
    private func wordFor(_ c: PlacedControl) -> String? {
        guard c.kind != .faceButton, let symbol = legend(c).symbol, !Self.keptSymbols.contains(symbol) else { return nil }
        switch symbol {
        case "plus": return "+"
        case "minus": return "\u{2212}"
        case "house": return "Home"
        case "camera", "camera.viewfinder", "viewfinder": return "Capture"
        case "rectangle.on.rectangle": return "View"
        case "star", "star.fill": return "Star"
        case "logo.xbox": return "Xbox"
        case "playstation.logo": return "PS"
        case "mic.slash": return "Mute"
        default:
            // The name printed on this model's button, not the preset's.
            // The model's own name, else the family's short one ("Create",
            // not "Create / Share"), else the first of a combined name.
            var n = c.name ?? c.inputs.buttons.first.map { b in
                layout.modelNames.renamed[b] ?? ButtonNames.short(b, family: layout.family, model: layout.modelNames)
                    ?? ButtonNames.label(b, family: layout.family, model: layout.modelNames, choice: .automatic)
            } ?? name?(c) ?? "Menu"
            if n.hasPrefix("Button ") { n = name?(c) ?? n }
            if let slash = n.range(of: " / ") { n = String(n[..<slash.lowerBound]) }
            if let paren = n.range(of: " (") { n = String(n[..<paren.lowerBound]) }
            if n.hasSuffix(" button") { n = String(n.dropLast(7)) }
            return n
        }
    }

    // MARK: - Key

    /// Each key column's width, as a fraction of the drawing's width: the
    /// longest entry on either side (measured at a typical panel width),
    /// between 0.12 and `maxKey`, so short captions leave the drawing more
    /// room; a longer one wraps to two lines.
    private var keyFraction: CGFloat {
        let keyed = referenceBands, laid = stack(keyed)
        // At a typical panel: the Live Visualizer's panels stack at up to
        // 640 points in a window at least 1080 wide.
        let w: CGFloat = 560
        var texts: [String] = []
        for (n, b) in keyed.enumerated() {
            for c in b.controls {
                if let t = keyText(c, size: controlFrame(c, band: b, top: laid.tops[n], width: w).size) { texts.append(t) }
            }
        }
        let cacheKey = "\(layout.id.rawValue)|\(variant ?? "")|" + texts.joined(separator: "\u{1}")
        if let hit = Self.fractionCache[cacheKey] { return hit }
        let widest = texts.map { CaptionLayout.measure($0, fontSize: CaptionLayout.fontSize(forWidth: w)) }.max() ?? 0
        let fraction = min(maxKey, max(0.12, (widest + 10) / w))
        if Self.fractionCache.count > 128 { Self.fractionCache.removeAll() }
        Self.fractionCache[cacheKey] = fraction
        return fraction
    }

    nonisolated(unsafe) private static var fractionCache: [String: CGFloat] = [:]

    /// The room above the drawing when there is a key: enough for a line
    /// to come down to the top edge, and, when many controls share the top
    /// row, room for their captions above it: a line each for the first
    /// few, then half a line each for a long row (the Adaptive Controller's
    /// jacks), since the key centers a crowd on its controls.
    private var topInset: CGFloat {
        let keyed = referenceBands, laid = stack(keyed)
        let w: CGFloat = 560
        var frames: [CGRect] = []
        for (n, b) in keyed.enumerated() {
            for c in b.controls where !(caption(c) ?? "").isEmpty {
                frames.append(Self.drawnBounds(c, controlFrame(c, band: b, top: laid.tops[n], width: w)))
            }
        }
        guard let top = frames.map(\.minY).min() else { return keyRoom }
        let row = frames.filter { $0.midY - top < 16 }
        let perSide = max(row.filter { $0.midX < w / 2 }.count, row.filter { $0.midX >= w / 2 }.count)
        let extra = CGFloat(max(0, perSide - 1))
        return keyRoom + min(extra, 6) * 0.028 + max(0, extra - 6) * 0.014
    }

    /// Whether captions are drawn as a key beside the drawing: when any
    /// control has one, or a control too small to hold its own name.
    private var keyOn: Bool {
        guard showCaptions else { return false }
        let controls = [LayoutFace.top, .front, .back].flatMap { drawn($0) }
        if controls.contains(where: { !(caption($0) ?? "").isEmpty }) { return true }
        // Or a control whose name would not be readable inside it, at a
        // typical panel width with the key's narrower drawing.
        let keyed = referenceBands, laid = stack(keyed)
        return keyed.enumerated().contains { n, b in
            b.controls.contains { !legendFits($0, size: controlFrame($0, band: b, top: laid.tops[n], width: 560).size) }
        }
    }

    /// One line of the key: the text, its side, where it sits, and the
    /// line to its control.
    struct KeyEntry: Identifiable {
        let id: String
        let text: String
        let left: Bool
        let y: CGFloat
        let anchor: CGPoint
        /// Where a line turns on the way, when no straight line is clear:
        /// one point for an elbow (level to above or below the control, then
        /// straight to it), two for a trace through a gap beside it.
        var bends: [CGPoint] = []
        var active: Bool
        /// One line, or two for a caption wider than its column.
        var lines = 1
    }

    /// The key: each caption in the column on its control's side, in the
    /// order the controls run top to bottom, a line apart, never on a
    /// control or another caption.
    private func keyEntries(bands: [Band], tops: [CGFloat], width w: CGFloat, height h: CGFloat,
                            key keyFraction: CGFloat, anchors: Bool = true) -> [KeyEntry] {
        struct Item { let c: PlacedControl; let bounds: CGRect; let text: String; var left: Bool; var shape: Obstacle? = nil; var lines = 1 }
        // A first layout pass can come with no size; there is nothing to lay out.
        guard w >= 100, h >= 40 else { return [] }
        var items: [Item] = []
        // Every drawn control, captioned or not, is something a line must
        // not run under.
        var allBounds: [(id: String, bounds: CGRect, obstacle: Obstacle)] = []
        for (n, b) in bands.enumerated() {
            for c in b.controls {
                let frame = controlFrame(c, band: b, top: tops[n], width: w)
                allBounds.append((c.id, Self.drawnBounds(c, frame), Self.obstacle(c, frame: frame)))
                guard let text = keyText(c, size: frame.size) else { continue }
                let bounds = Self.drawnBounds(c, frame)
                let left: Bool
                if let side = c.keySide { left = side == .left }
                else if bounds.midX < w / 2 - 0.5 { left = true }
                else if bounds.midX > w / 2 + 0.5 { left = false }
                else { left = c.callout == .left || (c.callout != .right && items.filter(\.left).count <= items.filter { !$0.left }.count) }
                items.append(Item(c: c, bounds: bounds, text: text, left: left, shape: Self.obstacle(c, frame: frame)))
            }
        }
        // The layout is the same until the drawing, its size or its
        // captions change; a press only relights a line.
        let cacheKey = "\(layout.id.rawValue)|\(variant ?? "")|\(Int(w))x\(h < 100_000 ? Int(h) : -1)|\(anchors)|\(keyFraction)|"
            + items.map { "\($0.c.id)=\($0.text)" }.joined(separator: "\u{1}")
        if let hit = Self.keyCache[cacheKey] {
            return hit.map { e in
                var e = e
                if let c = items.first(where: { $0.c.id == e.id })?.c { e.active = keyActive(c) }
                return e
            }
        }
        let fs = CaptionLayout.fontSize(forWidth: w)
        // A caption wider than its column takes two lines.
        let column = keyFraction * w - 4
        for i in items.indices where CaptionLayout.measure(items[i].text, fontSize: fs) > column { items[i].lines = 2 }
        // Routes and obstacles, remembered across every layout tried below
        // (a caption tried in the other column, two traded in the order):
        // a route depends only on the control, its side and the height.
        struct RouteKey: Hashable { let id: String; let left: Bool; let eighths: Int }
        var routeMemo: [RouteKey: (anchor: CGPoint, bends: [CGPoint])?] = [:]
        var blockMemo: [String: [Obstacle]] = [:]
        // Both columns laid out, with the captions that found no clear line.
        func layoutSides(_ items: [Item]) -> (entries: [KeyEntry], failed: Set<String>) {
        var out: [KeyEntry] = []
        var failed = Set<String>()
        for side in [true, false] {
            let sideItems = items.filter { $0.left == side }
            guard !sideItems.isEmpty else { continue }
            // The sizing pass passes no real height: as tall as the column needs.
            let lineCount = sideItems.reduce(0) { $0 + $1.lines }
            let span = h < 100_000 ? h : CGFloat(lineCount + 2) * fs * 1.45
            // At least a point: a first layout pass can come with no height.
            let lineH = max(1, min(fs * 1.45, (span - 4) / CGFloat(lineCount)))
            let top = lineH / 2 + 2, bottom = span - lineH / 2 - 2
            // A two-line caption is nearly two lines tall.
            func height(_ item: Item) -> CGFloat { item.lines == 2 ? lineH * 1.85 : lineH }
            let elbowX = side ? (keyFraction + keyGap * 0.5) * w : w - (keyFraction + keyGap * 0.5) * w
            func others(_ item: Item) -> [Obstacle] {
                if let hit = blockMemo[item.c.id] { return hit }
                // Every control but this one, one it sits inside (a wheel
                // rim), and one sitting inside it.
                let list = allBounds.filter { $0.id != item.c.id && !$0.bounds.contains(item.bounds) && !item.bounds.contains($0.bounds) }
                    .map(\.obstacle)
                blockMemo[item.c.id] = list
                return list
            }
            // Where a line from the column at height y may meet the control:
            // its outer edge (level when y is within its height), its middle,
            // its bottom, its top.
            func candidates(_ item: Item, _ y: CGFloat) -> [CGPoint] {
                let r = item.bounds
                var list = [edgePoint(item.c, r, towardY: y, left: side, axis: item.shape?.axis),
                            edgePoint(item.c, r, towardY: r.midY, left: side, axis: item.shape?.axis)]
                if Self.isRound(item.c) {
                    // On the rim, aimed at the elbow, then turned a little
                    // each way, so a line can come in between neighbors.
                    let base = atan2(y - r.midY, elbowX - r.midX)
                    for turn in [0.0, 0.35, -0.35, 0.7, -0.7, 1.05, -1.05] {
                        let t = base + turn
                        list.append(CGPoint(x: r.midX + (r.width / 2 + 1) * cos(t), y: r.midY + (r.height / 2 + 1) * sin(t)))
                    }
                }
                list += [bottomPoint(item), topPoint(item)]
                return list
            }
            // A control's lowest and highest drawn points: on a turned
            // capsule, the ends of its axis, not the corners of its box.
            func bottomPoint(_ item: Item) -> CGPoint {
                guard let (p, q, rad) = item.shape?.axis else { return CGPoint(x: item.bounds.midX, y: item.bounds.maxY + 1) }
                let e = p.y > q.y ? p : q
                return CGPoint(x: e.x, y: e.y + rad + 1)
            }
            func topPoint(_ item: Item) -> CGPoint {
                guard let (p, q, rad) = item.shape?.axis else { return CGPoint(x: item.bounds.midX, y: item.bounds.minY - 1) }
                let e = p.y < q.y ? p : q
                return CGPoint(x: e.x, y: e.y - rad - 1)
            }
            func clearAnchor(_ item: Item, _ y: CGFloat, _ block: [Obstacle]) -> (anchor: CGPoint, bends: [CGPoint])? {
                let elbow = CGPoint(x: elbowX, y: y)
                func clear(_ a: CGPoint, _ b: CGPoint) -> Bool { !block.contains { Self.segment(a, b, hits: $0, margin: 2) } }
                if let a = candidates(item, y).first(where: { clear(elbow, $0) }) { return (a, []) }
                // An elbow: level to directly above or below the control,
                // then straight down or up to it.
                let r = item.bounds
                let top = topPoint(item), bottom = bottomPoint(item)
                if y < top.y - 2 {
                    let bend = CGPoint(x: top.x, y: y)
                    if clear(elbow, bend) && clear(bend, top) { return (top, [bend]) }
                }
                if y > bottom.y + 2 {
                    let bend = CGPoint(x: bottom.x, y: y)
                    if clear(elbow, bend) && clear(bend, bottom) { return (bottom, [bend]) }
                }
                // A trace: level, then down or up the nearest open channel
                // beside the control, then level into its side.
                let entry = edgePoint(item.c, r, towardY: r.midY, left: side, axis: item.shape?.axis)
                for step in stride(from: CGFloat(4), through: 80, by: 2) {
                    let x = side ? entry.x - step : entry.x + step
                    guard side ? x > elbowX + 2 : x < elbowX - 2 else { break }
                    let b1 = CGPoint(x: x, y: y), b2 = CGPoint(x: x, y: entry.y)
                    if clear(elbow, b1) && clear(b1, b2) && clear(b2, entry) { return (entry, [b1, b2]) }
                }
                return nil
            }
            func route(_ item: Item, _ y: CGFloat) -> (anchor: CGPoint, bends: [CGPoint])? {
                let key = RouteKey(id: item.c.id, left: side, eighths: Int((y * 8).rounded()))
                if let hit = routeMemo[key] { return hit }
                let found = clearAnchor(item, y, others(item))
                routeMemo[key] = found
                return found
            }
            // What each height in the column costs a caption: how far it
            // sits from its control's middle, more for a line that has to
            // bend (an elbow, more again for a trace), and a great deal for
            // a height with no clear line at all or far from the control.
            let reach = max(90, 8 * lineH)
            var costMemo: [String: [Float]] = [:]
            let slots = max(1, Int((bottom - top).rounded(.down)) + 1)
            func slotY(_ k: Int) -> CGFloat { top + CGFloat(k) }
            func costs(_ item: Item) -> [Float] {
                if let hit = costMemo[item.c.id] { return hit }
                let mid = item.bounds.midY, half = height(item) / 2 + 2
                var list = [Float](repeating: 0, count: slots)
                for k in 0..<slots {
                    let y = slotY(k), d = abs(y - mid)
                    if y < half || y > span - half { list[k] = .infinity; continue }
                    guard anchors else { list[k] = Float(d); continue }
                    if d > reach { list[k] = Float(20_000 + d); continue }
                    if let found = route(item, y) {
                        list[k] = Float(d + (found.bends.isEmpty ? 0 : found.bends.count == 1 ? 24 : 48))
                    } else {
                        list[k] = Float(10_000 + d)
                    }
                }
                costMemo[item.c.id] = list
                return list
            }
            // Heights where a caption's line would cross another line as
            // the column now stands, made dearer so the placement steers
            // around them (see the untangling below).
            var penalty: [String: Set<Int>] = [:]
            func cost(_ item: Item) -> [Float] {
                var c = costs(item)
                for k in penalty[item.c.id] ?? [] { c[k] += 400 }
                return c
            }
            // The captions in one order down the column, a line apart, each
            // as near its own control as the others allow: the cheapest such
            // placement, found exactly (dynamic programming over the
            // column's heights), so a crowd spreads both up and down around
            // its controls instead of being pushed down past them.
            func place(_ order: [Item]) -> [CGFloat] {
                let hs = order.map(height)
                var best: [[Float]] = [], from: [[Int]] = []
                for i in order.indices {
                    let c = cost(order[i])
                    var row = [Float](repeating: .infinity, count: slots), arg = [Int](repeating: -1, count: slots)
                    if i == 0 {
                        row = c
                    } else {
                        let gap = max(1, Int(((hs[i - 1] + hs[i]) / 2).rounded(.up)))
                        var low = Float.infinity, lowAt = -1
                        var k = gap
                        while k < slots {
                            let prev = best[i - 1][k - gap]
                            if prev < low { low = prev; lowAt = k - gap }
                            if low < .infinity { row[k] = c[k] + low; arg[k] = lowAt }
                            k += 1
                        }
                    }
                    best.append(row); from.append(arg)
                }
                guard let last = best.last, var k = last.indices.min(by: { last[$0] < last[$1] }), last[k] < .infinity else {
                    // More captions than the column holds at that spacing:
                    // stacked evenly from the top.
                    var y = top - lineH / 2, out: [CGFloat] = []
                    for h in hs { y += h; out.append(y - h / 2) }
                    return out
                }
                var ys = [CGFloat](repeating: 0, count: order.count)
                for i in order.indices.reversed() {
                    ys[i] = slotY(k)
                    if i > 0 { k = from[i][k] }
                }
                return ys
            }
            // Each line as drawn: from the column, level to the elbow, then
            // on to the control.
            func paths(_ order: [Item], _ ys: [CGFloat]) -> [[CGPoint]] {
                zip(order, ys).map { item, y in
                    let start = CGPoint(x: side ? keyFraction * w - 1 : w - keyFraction * w + 1, y: y)
                    let found = anchors ? route(item, y) : nil
                    return [start, CGPoint(x: elbowX, y: y)] + (found?.bends ?? []) + [found?.anchor ?? candidates(item, y)[0]]
                }
            }
            func crossings(_ ps: [[CGPoint]]) -> [(Int, Int)] {
                var out: [(Int, Int)] = []
                for i in ps.indices {
                    for j in ps.indices where j > i {
                        let hit = zip(ps[i], ps[i].dropFirst()).contains { s in
                            zip(ps[j], ps[j].dropFirst()).contains { t in Self.distance(s.0, s.1, t.0, t.1) < 0.75 }
                        }
                        if hit { out.append((i, j)) }
                    }
                }
                return out
            }
            // First order: by the height each caption would take alone;
            // captions wanting the same height go nearest the column first,
            // so lines to a row of controls nest.
            var list: [Item] = sideItems.map { item -> (Item, Int, CGFloat) in
                let c = costs(item)
                return (item, c.indices.min(by: { c[$0] < c[$1] }) ?? 0, side ? item.bounds.minX : -item.bounds.maxX)
            }.sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.2 < b.2 }.map(\.0)
            var ys = place(list)
            // Then untangled: where two lines still cross, the two captions
            // trade places, or one of them moves to another place in the
            // order (in a tight diamond of buttons the line to the far one
            // threads a gap, so a neighbor's caption has to go round it);
            // the order with the fewest crossings is kept while that is
            // fewer than before.
            if anchors {
                var crossed = crossings(paths(list, ys))
                var rounds = 0
                // Orders already tried, so a move that keeps the count level
                // (one crossing fixed, another made, for the next round to
                // fix) cannot go round in circles.
                var seen: Set<[String]> = [list.map(\.c.id)]
                var bestSoFar = (order: list, ys: ys, crossed: crossed)
                while !crossed.isEmpty && rounds < 40 {
                    rounds += 1
                    var trials: [[Item]] = []
                    for (i, j) in crossed.prefix(4) {
                        var swapped = list
                        swapped.swapAt(i, j)
                        trials.append(swapped)
                        for moving in [i, j] {
                            for to in list.indices where to != moving {
                                var moved = list
                                let item = moved.remove(at: moving)
                                moved.insert(item, at: to)
                                trials.append(moved)
                            }
                        }
                    }
                    var best: (order: [Item], ys: [CGFloat], crossed: [(Int, Int)])? = nil
                    for trial in trials where !seen.contains(trial.map(\.c.id)) {
                        seen.insert(trial.map(\.c.id))
                        let trialYs = place(trial)
                        let trialCrossed = crossings(paths(trial, trialYs))
                        if trialCrossed.count <= (best?.crossed.count ?? crossed.count) {
                            best = (trial, trialYs, trialCrossed)
                            if trialCrossed.isEmpty { break }
                        }
                    }
                    guard let found = best else { break }
                    (list, ys, crossed) = found
                    if crossed.count < bestSoFar.crossed.count { bestSoFar = (list, ys, crossed) }
                }
                (list, ys, crossed) = bestSoFar
                // Lines still crossing: each caption involved steers away
                // from the heights where its line would cross another, and
                // the column is placed again, kept when fewer lines cross.
                var steer = 0
                while !crossed.isEmpty && steer < 4 {
                    steer += 1
                    let ps = paths(list, ys)
                    let involved = Set(crossed.flatMap { [$0.0, $0.1] })
                    for i in involved {
                        let item = list[i], base = costs(item)
                        for k in 0..<slots where base[k] < 10_000 {
                            let p = paths([item], [slotY(k)])[0]
                            let hits = ps.indices.contains { j in
                                j != i && zip(p, p.dropFirst()).contains { s in
                                    zip(ps[j], ps[j].dropFirst()).contains { t in Self.distance(s.0, s.1, t.0, t.1) < 1.5 }
                                }
                            }
                            if hits { penalty[item.c.id, default: []].insert(k) }
                        }
                    }
                    let trialYs = place(list)
                    let trialCrossed = crossings(paths(list, trialYs))
                    if trialCrossed.count < crossed.count { ys = trialYs; crossed = trialCrossed } else { break }
                }
            }
            for (item, y) in zip(list, ys) {
                guard anchors else {
                    out.append(KeyEntry(id: item.c.id, text: item.text, left: side, y: y, anchor: .zero, active: false, lines: item.lines))
                    continue
                }
                let found = route(item, y)
                if found == nil { failed.insert(item.c.id) }
                out.append(KeyEntry(id: item.c.id, text: item.text, left: side, y: y,
                                    anchor: found?.anchor ?? candidates(item, y)[0], bends: found?.bends ?? [],
                                    active: keyActive(item.c), lines: item.lines))
            }
        }
        return (out, failed)
        }
        var (out, failed) = layoutSides(items)
        var current = items
        // A caption with no clear line on its side tries the other column,
        // one at a time; a move is kept when fewer captions are left
        // without a clear line.
        if anchors && !failed.isEmpty {
            for id in failed.sorted().prefix(8) {
                guard let i = current.firstIndex(where: { $0.c.id == id }) else { continue }
                var trial = current
                trial[i].left.toggle()
                let result = layoutSides(trial)
                if result.failed.count < failed.count { current = trial; (out, failed) = result }
                if failed.isEmpty { break }
            }
        }
        // Two lines that still cross: one of the two captions tries the
        // other column (a button near the middle can be reached from
        // either side), kept when fewer lines cross and no line is lost.
        if anchors {
            var crossed = Self.crossingPairs(out, width: w, key: keyFraction, gap: keyGap)
            var rounds = 0
            while !crossed.isEmpty && rounds < 6 {
                rounds += 1
                var better = false
                search: for pair in crossed {
                    for id in [pair.0, pair.1] {
                        guard let i = current.firstIndex(where: { $0.c.id == id }) else { continue }
                        var trial = current
                        trial[i].left.toggle()
                        let result = layoutSides(trial)
                        let trialCrossed = Self.crossingPairs(result.entries, width: w, key: keyFraction, gap: keyGap)
                        if result.failed.count <= failed.count && trialCrossed.count < crossed.count {
                            current = trial; (out, failed) = result; crossed = trialCrossed; better = true
                            break search
                        }
                    }
                }
                if !better { break }
            }
        }
        if Self.keyCache.count > 64 { Self.keyCache.removeAll() }
        Self.keyCache[cacheKey] = out
        return out
    }

    nonisolated(unsafe) private static var keyCache: [String: [KeyEntry]] = [:]

    /// The key lines that cross or touch, as pairs of control ids: each line
    /// runs from its caption, level to the elbow, then on to its control.
    static func crossingPairs(_ entries: [KeyEntry], width w: CGFloat, key kf: CGFloat, gap: CGFloat) -> [(String, String)] {
        func path(_ e: KeyEntry) -> [CGPoint] {
            let start = CGPoint(x: e.left ? kf * w - 1 : w - kf * w + 1, y: e.y)
            let elbow = CGPoint(x: e.left ? (kf + gap * 0.5) * w : w - (kf + gap * 0.5) * w, y: e.y)
            return [start, elbow] + e.bends + [e.anchor]
        }
        let paths = entries.map(path)
        var out: [(String, String)] = []
        for i in paths.indices {
            for j in paths.indices where j > i {
                let hit = zip(paths[i], paths[i].dropFirst()).contains { s in
                    zip(paths[j], paths[j].dropFirst()).contains { t in distance(s.0, s.1, t.0, t.1) < 0.75 }
                }
                if hit { out.append((entries[i].id, entries[j].id)) }
            }
        }
        return out
    }

    /// Something a key line must not run under: a control's drawn bounds,
    /// as an ellipse for a round control (round neighbors leave real gaps
    /// between them that a box would close), with a margin.
    struct Obstacle {
        let rect: CGRect
        let round: Bool
        /// A capsule set at an angle, as its axis and radius: its box would
        /// close the gaps beside it.
        var axis: (CGPoint, CGPoint, CGFloat)? = nil
    }

    /// A control as an obstacle at its drawn frame.
    static func obstacle(_ c: PlacedControl, frame: CGRect) -> Obstacle {
        if case .capsule(let angle) = c.shape, angle != 0 {
            let long = max(frame.width, frame.height), r = min(frame.width, frame.height) / 2
            let t = angle * .pi / 180 + (frame.width >= frame.height ? 0 : .pi / 2)
            let half = max(0, long / 2 - r)
            let d = CGPoint(x: cos(t) * half, y: sin(t) * half)
            return Obstacle(rect: drawnBounds(c, frame), round: false,
                            axis: (CGPoint(x: frame.midX - d.x, y: frame.midY - d.y), CGPoint(x: frame.midX + d.x, y: frame.midY + d.y), r))
        }
        return Obstacle(rect: drawnBounds(c, frame), round: isRound(c))
    }

    /// The closest the two segments come to each other.
    static func distance(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> CGFloat {
        func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
        func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
        func toSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let ab = sub(b, a), l2 = dot(ab, ab)
            let t = l2 == 0 ? 0 : max(0, min(1, dot(sub(p, a), ab) / l2))
            let c = CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
            return hypot(p.x - c.x, p.y - c.y)
        }
        // Crossing segments touch; otherwise the nearest endpoint pair decides.
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        if side(p1, p2, q1) * side(p1, p2, q2) < 0 && side(q1, q2, p1) * side(q1, q2, p2) < 0 { return 0 }
        return min(toSegment(p1, q1, q2), toSegment(p2, q1, q2), toSegment(q1, p1, p2), toSegment(q2, p1, p2))
    }

    static func isRound(_ c: PlacedControl) -> Bool {
        switch c.shape {
        case .circle, .disc, .octagonGate, .hybridDish: return true
        default: return c.kind == .stick || c.kind == .wheel
        }
    }

    /// Whether the line from a to b comes within `margin` of the obstacle.
    static func segment(_ a: CGPoint, _ b: CGPoint, hits o: Obstacle, margin: CGFloat) -> Bool {
        if let (p, q, r) = o.axis { return distance(a, b, p, q) < r + margin }
        guard o.round else { return segment(a, b, hits: o.rect.insetBy(dx: -margin, dy: -margin)) }
        // In the ellipse's own space it is a unit circle grown by the margin.
        let rx = o.rect.width / 2 + margin, ry = o.rect.height / 2 + margin
        guard rx > 0, ry > 0 else { return false }
        let p = CGPoint(x: (a.x - o.rect.midX) / rx, y: (a.y - o.rect.midY) / ry)
        let q = CGPoint(x: (b.x - o.rect.midX) / rx, y: (b.y - o.rect.midY) / ry)
        let dx = q.x - p.x, dy = q.y - p.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, -(p.x * dx + p.y * dy) / len2))
        let cx = p.x + dx * t, cy = p.y + dy * t
        return cx * cx + cy * cy < 1
    }

    /// Whether the straight line from a to b crosses the rectangle.
    static func segment(_ a: CGPoint, _ b: CGPoint, hits r: CGRect) -> Bool {
        // Liang-Barsky: clip the segment to the rectangle.
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        for (p, q) in [(-dx, a.x - r.minX), (dx, r.maxX - a.x), (-dy, a.y - r.minY), (dy, r.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return false }
            }
        }
        return true
    }

    /// Where a key line meets its control: the control's outer edge, level
    /// with the caption when the control spans that height (a straight
    /// line), on the curve for a round control.
    private func edgePoint(_ c: PlacedControl, _ r: CGRect, towardY y: CGFloat, left: Bool,
                           axis: (CGPoint, CGPoint, CGFloat)? = nil) -> CGPoint {
        let inset = min(4, r.height / 4)
        let ay = min(max(y, r.minY + inset), r.maxY - inset)
        // A turned capsule: its outline along that level, found by stepping
        // in from the box's side; at a level it does not reach, its middle.
        if let (p, q, rad) = axis {
            for level in [ay, r.midY] {
                var x = left ? r.minX : r.maxX
                while left ? x < r.midX : x > r.midX {
                    if Self.distance(CGPoint(x: x, y: level), CGPoint(x: x, y: level), p, q) <= rad {
                        return CGPoint(x: left ? x - 1 : x + 1, y: level)
                    }
                    x += left ? 0.5 : -0.5
                }
            }
        }
        var dx = r.width / 2
        let round: Bool = {
            switch c.shape { case .circle, .disc, .octagonGate, .hybridDish, .crossPad, .fourButtonPad: return true; default: break }
            return c.kind == .stick || c.kind == .wheel
        }()
        if round, r.height > 0 {
            let t = (ay - r.midY) / (r.height / 2)
            dx = r.width / 2 * sqrt(max(0, 1 - t * t))
        }
        return CGPoint(x: left ? r.midX - dx - 1 : r.midX + dx + 1, y: ay)
    }

    /// The key's text for a control: what it does, with its name first when
    /// the control is too small to hold the name readably.
    private func keyText(_ c: PlacedControl, size: CGSize) -> String? {
        let action = caption(c).flatMap { $0.isEmpty ? nil : $0 }
        guard !legendFits(c, size: size) else { return action }
        let name = wordFor(c) ?? legend(c).text ?? spoken(c, "")
        guard !name.isEmpty else { return action }
        return action.map { "\(name): \($0)" } ?? name
    }

    /// Whether the control is in use now, so its key line lights.
    private func keyActive(_ c: PlacedControl) -> Bool {
        if isOn(c) { return true }
        if c.inputs.axes.contains(where: { abs(state.axes[$0.index] ?? 0) > 0.3 }) { return true }
        if let spec = layout.surface(forControl: c.id), let t = spec.touchIndex, (state.buttons[t] ?? 0) > 0.5 { return true }
        return false
    }

    /// The legend's size inside its control, as the button and trigger
    /// views draw it, and whether that is readable (7.5 pt or more, and as
    /// wide as the text).
    private func legendFits(_ c: PlacedControl, size: CGSize) -> Bool {
        if wordFor(c) != nil, !crowdedPills.contains(c.id) { return true }
        let lg = shownLegend(c)
        switch c.kind {
        case .trigger:
            let raw = size.height * 0.42
            guard let text = lg.text, !text.isEmpty else { return true }
            return raw >= 7.5 && CaptionLayout.measure(text, fontSize: max(7.5, min(12, raw))) * 1.1 <= size.width - 4
        case .stick, .lever, .hat, .dpad, .trackpad, .wheel, .slider, .dial, .pedal, .light, .port:
            return true
        default:
            let raw = legendRaw(c, size)
            if lg.symbol != nil { return raw >= 7 }
            guard let text = lg.text, !text.isEmpty else { return true }
            return raw >= 7.5 && CaptionLayout.measure(text, fontSize: max(7.5, min(14, raw))) * 1.1 <= size.width - 2
        }
    }

    /// A button's legend size before limits: half a face button, and on a
    /// wide, short button (a bumper, a Z) most of its height, as the 1.5
    /// shoulder pills had.
    private func legendRaw(_ c: PlacedControl, _ size: CGSize) -> CGFloat {
        if c.kind == .faceButton { return min(size.width, size.height) * 0.5 }
        if size.width >= size.height * 1.8 { return size.height * 0.55 }
        return min(size.width, size.height) * 0.42
    }

    private func leaderLines(_ entries: [KeyEntry], key keyFraction: CGFloat) -> some View {
        Canvas { ctx, size in
            let k = keyFraction * size.width
            for e in entries {
                let start = CGPoint(x: e.left ? k - 1 : size.width - k + 1, y: e.y)
                let elbow = CGPoint(x: e.left ? k + keyGap * size.width * 0.5 : size.width - k - keyGap * size.width * 0.5, y: e.y)
                var path = Path()
                path.move(to: start)
                path.addLine(to: elbow)
                for bend in e.bends { path.addLine(to: bend) }
                path.addLine(to: e.anchor)
                let tint = e.active ? Color.green.opacity(0.9) : Color.primary.opacity(0.28)
                ctx.stroke(path, with: .color(tint), lineWidth: e.active ? 1.2 : 0.75)
                ctx.fill(Path(ellipseIn: CGRect(x: e.anchor.x - 1.6, y: e.anchor.y - 1.6, width: 3.2, height: 3.2)),
                         with: .color(tint))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func keyLabel(_ e: KeyEntry, width w: CGFloat, key keyFraction: CGFloat) -> some View {
        let k = keyFraction * w
        let fs = CaptionLayout.fontSize(forWidth: w)
        return Text(e.text)
            .font(.system(size: fs))
            .foregroundStyle(e.active ? Color.green : Color.secondary)
            .lineLimit(e.lines)
            .truncationMode(.tail)
            .multilineTextAlignment(e.left ? .trailing : .leading)
            .frame(width: k - 4, height: CGFloat(e.lines) * fs * 1.3, alignment: e.left ? .trailing : .leading)
            .position(x: e.left ? (k - 4) / 2 : w - (k - 4) / 2, y: e.y)
            .help(e.text)
            .accessibilityHidden(true)
    }

    private func controlFrame(_ c: PlacedControl, in rect: CGRect, width w: CGFloat) -> CGRect {
        // The back is drawn at 0.6 of the width where its layout assumed
        // 0.76, so its controls shrink with it.
        let scale: CGFloat = c.face == .back ? 0.6 / 0.76 : 1
        let cw = c.size * w * scale
        let ch = (c.height ?? c.size) * w * scale
        let x = rect.minX + c.center.x * rect.width
        let y = rect.minY + c.center.y * rect.height
        return CGRect(x: x - cw / 2, y: y - ch / 2, width: cw, height: ch)
    }

    // MARK: - Controls

    private func controlView(_ c: PlacedControl, size: CGSize) -> some View {
        let content: AnyView
        if case .notReported(let why) = c.readable {
            content = AnyView(notReported(c, size: size).help(why))
            return content
        }
        // Read only in some setups: drawn a little dimmer, the reason on hover.
        if case .conditional(let why) = c.readable {
            return AnyView(controlBody(c, size: size).opacity(0.75).help(why))
        }
        return controlBody(c, size: size)
    }

    private func controlBody(_ c: PlacedControl, size: CGSize) -> AnyView {
        let content: AnyView
        switch c.kind {
        case .stick where c.shape == .crossPad:
            // A cross pad sitting where a stick would (the original 8BitDo
            // Lite): drawn as a D-pad that reads the stick's axes.
            content = AnyView(dpad(c, size: size))
        case .stick, .lever:
            content = AnyView(stick(c, size: size))
        case .hat:
            content = AnyView(dpad(c, size: size))
        case .trackpad:
            content = AnyView(trackpad(c, size: size))
        case .dpad:
            content = AnyView(dpad(c, size: size))
        case .trigger(let kind):
            content = AnyView(trigger(c, kind: kind, size: size))
        case .light:
            // Output only: nothing to bind, so not a button.
            return AnyView(light(c, size: size))
        case .wheel:
            content = AnyView(wheel(c, size: size))
        case .slider, .dial, .pedal:
            content = AnyView(analogBar(c, size: size))
        case .port:
            return AnyView(port(c, size: size))
        default:
            content = AnyView(button(c, size: size))
        }
        // Which rows set the deadzone drawn on it, and to what, on hover.
        if let dz = deadzone(c) { return inspect(c, AnyView(content.help(dz.help))) }
        return inspect(c, content)
    }

    private func isOn(_ c: PlacedControl) -> Bool {
        c.inputs.buttons.contains { (state.buttons[$0] ?? 0) > 0.5 }
            || (c.kind != .stick && touched(c))
            || c.inputs.press.map { (state.buttons[$0] ?? 0) > 0.5 } == true
            || c.inputs.digitalCopy.map { (state.buttons[$0] ?? 0) > 0.5 } == true
            || (c.inputs.edgeClicks ?? []).contains { (state.buttons[$0] ?? 0) > 0.5 }
            || hatOn(c)
    }

    /// A control that is one direction of a hat, held that way.
    private func hatOn(_ c: PlacedControl) -> Bool {
        guard let h = c.inputs.hat, let dir = c.inputs.hatDirection, let v = state.hats[h] else { return false }
        switch dir {
        case .up: return v.y > 0.5
        case .down: return v.y < -0.5
        case .left: return v.x < -0.5
        case .right: return v.x > 0.5
        }
    }

    private func touched(_ c: PlacedControl) -> Bool {
        c.inputs.touch.map { (state.buttons[$0] ?? 0) > 0.5 } == true
    }

    private func shapePath(_ shape: ControlShape, in size: CGSize) -> Path {
        let r = CGRect(origin: .zero, size: size)
        switch shape {
        case .circle, .disc, .octagonGate, .hybridDish:
            return Path(ellipseIn: r)
        case .capsule(let angle):
            let p = Path(roundedRect: r, cornerRadius: min(size.width, size.height) / 2)
            guard angle != 0 else { return p }
            return p.applying(CGAffineTransform(translationX: -r.midX, y: -r.midY)
                .concatenating(CGAffineTransform(rotationAngle: angle * .pi / 180))
                .concatenating(CGAffineTransform(translationX: r.midX, y: r.midY)))
        case .roundedRect(let corner):
            return Path(roundedRect: r, cornerRadius: min(size.width, size.height) * corner)
        case .squircle:
            return Path(roundedRect: r, cornerRadius: min(size.width, size.height) * 0.3, style: .continuous)
        case .trapezoid(let top):
            var p = Path()
            let inset = (1 - top) / 2 * size.width
            p.move(to: CGPoint(x: inset, y: 0))
            p.addLine(to: CGPoint(x: size.width - inset, y: 0))
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.addLine(to: CGPoint(x: 0, y: size.height))
            p.closeSubpath()
            return p
        case .crossPad, .fourButtonPad:
            return Path(ellipseIn: r)
        }
    }

    /// A zone's color, as the touchpad editor draws it.
    static func zoneColor(_ index: Int) -> Color {
        let palette = TouchpadRegion.colorPalette
        switch palette[max(0, min(palette.count - 1, index))] {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        default: return .gray
        }
    }

    private func color(_ t: LayoutColor?) -> Color? {
        switch t {
        case .xboxGreen?: return Color(red: 0.36, green: 0.73, blue: 0.29)
        case .xboxRed?: return Color(red: 0.89, green: 0.25, blue: 0.22)
        case .xboxBlue?: return Color(red: 0.2, green: 0.5, blue: 0.95)
        case .xboxYellow?: return Color(red: 0.98, green: 0.76, blue: 0.16)
        case .psBlue?: return Color(red: 0.45, green: 0.65, blue: 1.0)
        case .psRed?: return Color(red: 0.95, green: 0.35, blue: 0.4)
        case .psPink?: return Color(red: 0.93, green: 0.5, blue: 0.8)
        case .psGreen?: return Color(red: 0.3, green: 0.8, blue: 0.6)
        case .gameCubeGreen?: return Color(red: 0.3, green: 0.75, blue: 0.45)
        case .gameCubeRed?: return Color(red: 0.9, green: 0.3, blue: 0.3)
        case .snesRed?: return Color(red: 0.85, green: 0.2, blue: 0.25)
        case .snesYellow?: return Color(red: 0.95, green: 0.8, blue: 0.2)
        case .snesBlue?: return Color(red: 0.25, green: 0.4, blue: 0.85)
        case .snesGreen?: return Color(red: 0.25, green: 0.65, blue: 0.35)
        case .gray?: return .secondary
        case nil: return nil
        }
    }

    private func button(_ c: PlacedControl, size: CGSize) -> AnyView {
        if let word = pillWord(c) { return AnyView(pill(c, word: word, size: size)) }
        return AnyView(glyphButton(c, size: size))
    }

    /// A button written as its name in a capsule, the 1.5 shoulder and menu
    /// pill: gray, green when pressed.
    private func pill(_ c: PlacedControl, word: String, size: CGSize) -> some View {
        let on = isOn(c)
        return ZStack {
            Capsule().fill(on ? Color.green.opacity(0.25) : Color.secondary.opacity(0.15))
            Capsule().stroke(on ? Color.green : Color.secondary.opacity(0.35), lineWidth: 1)
            Text(word)
                .font(.system(size: max(7, size.height - 7), weight: .semibold))
                .foregroundStyle(on ? .green : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(c, word))
        .accessibilityValue(on ? "pressed" : "released")
    }

    private func glyphButton(_ c: PlacedControl, size: CGSize) -> some View {
        let on = isOn(c)
        let lg = legend(c)
        // The printed color belongs to the printed legend; relettered by the
        // face names setting, the button is drawn plain.
        let own = ownLegend?(c)
        let relettered = own.map { $0.text != lg.text || $0.symbol != lg.symbol } ?? (c.printed != nil && lg.text != c.printed)
        let tint = relettered ? nil : color(c.tint)
        let shape = shapePath(c.shape, in: size)
        let fontSize = max(7, min(14, legendRaw(c, size)))
        return ZStack {
            shape.fill(on ? (tint ?? .green).opacity(tint == nil ? 0.25 : 0.4) : Color.secondary.opacity(0.18))
            shape.stroke(on ? (tint ?? .green) : Color.secondary.opacity(0.35), lineWidth: 1.5)
            // Too small to read: the name is in the key instead.
            if !legendFits(c, size: size) {
                EmptyView()
            } else if let symbol = shownLegend(c).symbol {
                Image(systemName: symbol)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(tint.map { on ? $0 : $0.opacity(0.85) } ?? (on ? .green : .secondary))
            } else if let text = shownLegend(c).text {
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint.map { on ? $0 : $0.opacity(0.85) } ?? (on ? .green : .secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(c, "Button"))
        .accessibilityValue(on ? "pressed" : "released")
    }

    private func stick(_ c: PlacedControl, size: CGSize) -> some View {
        let on = isOn(c)
        let touch = touched(c)
        // A lever that reports as a hat moves the dot by its direction.
        let hat = c.inputs.hat.flatMap { state.hats[$0] }
        // Every stick pair it lists (an arcade lever on LS or RS), the one
        // furthest from center, else the hat (the same lever in DP mode).
        let xs = c.inputs.axes.filter { $0.role == .x }, ys = c.inputs.axes.filter { $0.role == .y }
        var xAxis: Float = 0, yAxis: Float = 0
        for (ax, ay) in zip(xs, ys) {
            let x = state.axes[ax.index] ?? 0, y = state.axes[ay.index] ?? 0
            if x * x + y * y > xAxis * xAxis + yAxis * yAxis { xAxis = x; yAxis = y }
        }
        if abs(xAxis) < 0.05, abs(yAxis) < 0.05, let hat, hat.x != 0 || hat.y != 0 {
            xAxis = hat.x; yAxis = -hat.y
        }
        let d = min(size.width, size.height)
        return ZStack {
            Circle().fill(on ? Color.green.opacity(0.25) : Color.secondary.opacity(0.18))
            Circle().stroke(touch ? Color.accentColor : (on ? Color.green : Color.secondary.opacity(0.4)),
                            lineWidth: touch ? 2 : 1.5)
            Path { p in
                p.move(to: CGPoint(x: d / 2, y: 0)); p.addLine(to: CGPoint(x: d / 2, y: d))
                p.move(to: CGPoint(x: 0, y: d / 2)); p.addLine(to: CGPoint(x: d, y: d / 2))
            }
            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            // The rows' deadzones, on the dot's own scale: the dot's middle
            // inside the red ring is inside the deadzone.
            let travel = CGRect(x: d / 2 - d * 0.36, y: d / 2 - d * 0.36, width: d * 0.72, height: d * 0.72)
            if let dz = deadzone(c) { deadzoneRings(dz, travel: travel, lines: false).frame(width: d, height: d) }
            Circle()
                .fill(Color.accentColor)
                .frame(width: max(6, d * 0.19), height: max(6, d * 0.19))
                .offset(x: CGFloat(xAxis) * d * 0.36, y: CGFloat(yAxis) * d * 0.36)
            // The rings' lines again over the dot, which is about as wide as
            // a 25% deadzone and would hide it at rest.
            if let dz = deadzone(c) { deadzoneRings(dz, travel: travel, fill: false).frame(width: d, height: d) }
        }
        .frame(width: d, height: d)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(c, "Stick"))
        .accessibilityValue(SpokenLive.stick(x: xAxis, y: yAxis) + (on ? ", pressed" : "") + (touch ? ", touched" : ""))
    }

    private func trackpad(_ c: PlacedControl, size: CGSize) -> some View {
        let spec = layout.surface(forControl: c.id)
        let pressed = spec?.pressIndex.map { (state.buttons[$0] ?? 0) > 0.5 } ?? isOn(c)
        let touchedNow = spec?.touchIndex.map { (state.buttons[$0] ?? 0) > 0.5 } ?? false
        var points: [CGPoint] = []
        if let axes = spec?.positionAxes {
            var x = CGFloat(state.axes[axes.x] ?? 0), y = CGFloat(state.axes[axes.y] ?? 0)
            // A pad set at an angle on the body (the 2015 Steam Controller's,
            // 15 degrees) reports in its own frame; turn the dot into the body's.
            // The angle is SDL's, for y up; these axes are y down, so the
            // same turn is the opposite sign here.
            if let deg = spec?.rotationDegrees, deg != 0 {
                let r = -deg * .pi / 180
                (x, y) = (x * cos(r) - y * sin(r), x * sin(r) + y * cos(r))
            }
            if touchedNow || abs(x) > 0.002 || abs(y) > 0.002 { points.append(CGPoint(x: (x + 1) / 2, y: (y + 1) / 2)) }
        }
        let live = spec.map { liveTouchSurfaces.contains($0.surface) } ?? false
        if let s = spec?.surface, !live { points += touchPoints(s) }
        let pressure = spec?.pressureAxis.map { CGFloat(state.axes[$0] ?? 0) } ?? 0
        let outline: Path = {
            let r = CGRect(origin: .zero, size: size)
            switch spec?.outline ?? .roundedSquare {
            case .circle: return Path(ellipseIn: r)
            case .rect: return Path(roundedRect: r, cornerRadius: min(size.width, size.height) * 0.08)
            default: return Path(roundedRect: r, cornerRadius: min(size.width, size.height) * 0.18, style: .continuous)
            }
        }()
        let active = touchedNow || !points.isEmpty
        return ZStack {
            outline.fill(pressed ? Color.green.opacity(0.35) : Color.black.opacity(0.25))
            if pressure > 0.02 {
                outline.fill(Color.mint.opacity(0.08 + 0.25 * min(1, pressure)))
            }
            Path { p in
                p.move(to: CGPoint(x: size.width / 2, y: 6)); p.addLine(to: CGPoint(x: size.width / 2, y: size.height - 6))
                p.move(to: CGPoint(x: 12, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 12, y: size.height / 2))
            }
            .stroke(Color.mint.opacity(0.15), lineWidth: 0.5)
            // A pad read as axes (a Steam pad): its rows' deadzones, the
            // pad's edges being full travel.
            if let dz = deadzone(c) {
                deadzoneRings(dz, travel: CGRect(origin: .zero, size: size))
                    .frame(width: size.width, height: size.height)
            }
            outline.stroke(pressed ? Color.green : Color.mint.opacity(active ? 0.9 : 0.5), lineWidth: pressed ? 2 : 1)
                .shadow(color: pressed ? Color.green.opacity(0.7) : .clear, radius: pressed ? 10 : 0)
            // The zones, the one under a finger filled.
            if spec?.surface == 0, !zones.isEmpty {
                ForEach(zones) { z in
                    let r = CGRect(x: z.minX * size.width, y: z.minY * size.height,
                                   width: max(0, z.maxX - z.minX) * size.width, height: max(0, z.maxY - z.minY) * size.height)
                    let on = zoneOn(z.id)
                    let tint = Self.zoneColor(z.colorIndex)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint.opacity(on ? 0.6 : 0.18))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(tint.opacity(on ? 1 : 0.55), lineWidth: on ? 1.5 : 0.75))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .accessibilityHidden(true)
                }
            }
            fingerDots(points, size: size)
            if live, let s = spec?.surface {
                // 30 Hz is plenty for a dot; it stops under the editor and
                // while the app is in the background. The outline lights
                // here too, since a resting finger changes nothing else.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: suspended || livePaused)) { _ in
                    let pts = touchPoints(s)
                    ZStack {
                        if !pts.isEmpty && !pressed {
                            outline.stroke(Color.mint.opacity(0.9), lineWidth: 1)
                        }
                        fingerDots(pts, size: size)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(c, spec?.name ?? "Trackpad"))
        .accessibilityValue(pressed ? "pressed"
            : (active || (live && spec.map { !touchPoints($0.surface).isEmpty } == true) ? "touched" : "not touched"))
    }

    private func fingerDots(_ points: [CGPoint], size: CGSize) -> some View {
        ForEach(Array(points.enumerated()), id: \.offset) { i, p in
            // First finger mint, second cyan, as in 1.5.
            Circle()
                .fill(i == 0 ? Color.mint : Color.cyan)
                .frame(width: max(6, size.width * 0.13), height: max(6, size.width * 0.13))
                .shadow(color: (i == 0 ? Color.mint : Color.cyan).opacity(0.6), radius: 4)
                .position(x: min(max(p.x, 0), 1) * size.width, y: min(max(p.y, 0), 1) * size.height)
        }
    }

    private func dpad(_ c: PlacedControl, size: CGSize) -> some View {
        // A D-pad on axes (a pad read from its descriptor, a cross pad in
        // a stick's place) counts past the middle of each half.
        let ax = c.inputs.axes.first { $0.role == .x }.map { state.axes[$0.index] ?? 0 } ?? 0
        let ay = c.inputs.axes.first { $0.role == .y }.map { state.axes[$0.index] ?? 0 } ?? 0
        // The hat, unless it is centered and the axes say otherwise (a
        // D-pad switched to send a stick).
        let hatNow = c.inputs.hat.flatMap { state.hats[$0] }
        let hat: (x: Float, y: Float) = {
            if let h = hatNow, h.x != 0 || h.y != 0 { return (h.x, h.y) }
            return (ax, -ay)
        }()
        let clicks = c.inputs.edgeClicks ?? []
        func click(_ i: Int) -> Bool { i < clicks.count && (state.buttons[clicks[i]] ?? 0) > 0.5 }
        // Edge clicks are up, right, left, down (the 2015 Steam Controller order).
        let up = hat.y > 0.5 || click(0), right = hat.x > 0.5 || click(1)
        let left = hat.x < -0.5 || click(2), down = hat.y < -0.5 || click(3)
        let d = min(size.width, size.height)
        let arm = d * 0.34
        // A cross pad that clicks in (the original Lite's, as L3 or R3).
        let pressed = c.inputs.press.map { (state.buttons[$0] ?? 0) > 0.5 } == true
        func armView(_ on: Bool, _ dx: CGFloat, _ dy: CGFloat, _ symbol: String) -> some View {
            RoundedRectangle(cornerRadius: arm * 0.2)
                .fill(on ? Color.green.opacity(0.18) : Color.secondary.opacity(0.10))
                .overlay(Image(systemName: symbol).font(.system(size: max(6, arm * 0.6)))
                    .foregroundStyle(on ? Color.green : Color.secondary.opacity(0.55)))
                .frame(width: arm, height: arm)
                .offset(x: dx * arm, y: dy * arm)
        }
        return ZStack {
            Circle().fill(pressed ? Color.green.opacity(0.35) : Color.clear).frame(width: arm * 0.8, height: arm * 0.8)
            armView(up, 0, -1, "arrowtriangle.up.fill")
            armView(down, 0, 1, "arrowtriangle.down.fill")
            armView(left, -1, 0, "arrowtriangle.left.fill")
            armView(right, 1, 0, "arrowtriangle.right.fill")
        }
        .frame(width: d, height: d)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(c, "D-pad"))
        .accessibilityValue({
            let dirs = [up ? "up" : nil, down ? "down" : nil, left ? "left" : nil, right ? "right" : nil].compactMap { $0 }
            return (dirs.isEmpty ? "centered" : dirs.joined(separator: " ")) + (pressed ? ", pressed" : "")
        }())
    }

    private func trigger(_ c: PlacedControl, kind: TriggerKind, size: CGSize) -> some View {
        let axis = c.inputs.axes.first { $0.role == .analog }?.index
        let value = axis.map { CGFloat(min(1, max(0, state.axes[$0] ?? 0))) } ?? (isOn(c) ? 1 : 0)
        let shape = shapePath(c.shape, in: size)
        let lg = legend(c)
        let on = value > 0.05 || isOn(c)
        let tint: Color = c.center.x < 0.5 ? .blue : .red
        // A digital trigger only presses: no percent and no threshold.
        let analog: Bool = { if case .analog = kind { return axis != nil }; return false }()
        let dz = analog ? deadzone(c) : nil
        // The orange line where each row starts to count, as in 1.5: the
        // rows' own thresholds when the panel has rows on it, else the
        // threshold the panel passes.
        let marks: [CGFloat] = (dz.map { $0.thresholds } ?? (analog ? axis.flatMap(threshold).map { [$0] } ?? [] : []))
            .map { CGFloat(min(1, max(0, $0))) }
        let name = legendFits(c, size: size) ? lg.text ?? "" : ""
        let reading = "\(Int((value * 100).rounded()))%"
        // The name and percent side by side when they fit at full size,
        // else one above the other (a little smaller on a short trigger),
        // else side by side shrinking to fit, the percent only from 44
        // points wide, as before.
        let fontSize = max(7, min(12, size.height * 0.42))
        let stackedSize = min(fontSize, (size.height - 4) / 2.5)
        let sideBySide = analog && (name.isEmpty ? 0 : CaptionLayout.measure(name, fontSize: fontSize) + 3)
            + CaptionLayout.measure("100%", fontSize: fontSize) <= size.width - 6
        let stacked = analog && !sideBySide && !name.isEmpty && stackedSize >= 7.5
            && max(CaptionLayout.measure(name, fontSize: stackedSize), CaptionLayout.measure("100%", fontSize: stackedSize)) <= size.width - 6
        let percent = analog && (sideBySide || stacked || size.width > 44) ? reading : nil
        return ZStack(alignment: .bottom) {
            shape.fill(Color.secondary.opacity(0.15))
            shape.fill(tint.gradient)
                .mask(alignment: .bottom) { Rectangle().frame(height: size.height * value) }
            // The calibration sheet's bands over the fill: red where the
            // trigger is ignored, green where it already counts as full.
            if let dz {
                let inner = CGFloat(min(1, max(0, dz.thresholds.min() ?? dz.right)))
                shape.fill(Color.red.opacity(0.22))
                    .mask(alignment: .bottom) { Rectangle().frame(height: size.height * inner) }
                if dz.outerRight < 0.99 {
                    shape.fill(Color.green.opacity(0.22))
                        .mask(alignment: .top) { Rectangle().frame(height: size.height * CGFloat(1 - max(0, dz.outerRight))) }
                }
            }
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Rectangle().fill(Color.orange.opacity(0.7)).frame(height: 1)
                    .offset(y: -size.height * mark)
            }
            shape.stroke(on ? tint : Color.secondary.opacity(0.35), lineWidth: 1)
            Group {
                if stacked {
                    VStack(spacing: 0) {
                        Text(name).fontWeight(.semibold)
                        Text(percent ?? "").monospacedDigit().foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 3) {
                        Text(name).fontWeight(.semibold)
                        if let percent { Text(percent).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
            }
            .font(.system(size: stacked ? stackedSize : fontSize, design: .rounded))
            .foregroundStyle(on ? .primary : .secondary)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(c, "Trigger"))
        .accessibilityValue(SpokenLive.trigger(Float(value)))
    }

    private func light(_ c: PlacedControl, size: CGSize) -> some View {
        // Only a Sony light bar takes the preset's color; player and
        // status lights are drawn unlit.
        let bar = c.id.hasPrefix("lightbar") || c.id == "lightstrip"
        let tint = bar ? lightColor : nil
        return shapePath(c.shape, in: size)
            .fill((tint ?? .secondary).opacity(tint == nil ? (bar ? 0.5 : 0.25) : 0.9))
            .shadow(color: tint?.opacity(0.7) ?? .clear, radius: tint == nil ? 0 : 4)
            .frame(width: size.width, height: size.height)
            .accessibilityLabel(spoken(c, "Light"))
    }

    /// A steering wheel: its rim, with a mark at the top that turns as far
    /// as the wheel does, and the angle written beside it (degrees when the
    /// wheel's range is known, else how far toward full lock).
    private func wheel(_ c: PlacedControl, size: CGSize) -> some View {
        let axis = c.inputs.axes.first?.index
        let v = axis.flatMap { state.axes[$0] }.map(CGFloat.init) ?? 0
        let d = min(size.width, size.height)
        let range = layout.steeringDegrees(variant: variant)
        // The real angle when the range is known (a 900 degree wheel turns
        // 450 each way), else a quarter turn each way at full lock.
        let angle = Double(v) * ((range ?? 180) / 2)
        let reading: String = {
            if let range {
                let a = Int((Double(v) * range / 2).rounded())
                return a == 0 ? "0°" : (a < 0 ? "\(-a)° left" : "\(a)° right")
            }
            let pct = Int((abs(v) * 100).rounded())
            return pct == 0 ? "Centered" : "\(pct)% \(v < 0 ? "left" : "right")"
        }()
        let rim = max(2, d * 0.06)
        // Degrees each way from the top at full lock, as the mark turns.
        let lock = (range ?? 180) / 2
        let dz = deadzone(c)
        return ZStack {
            // Inside the frame, so a caption beside it never sits on the rim.
            Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: rim)
            // The rows' deadzones on the rim, as the calibration sheet
            // colors them: red where turning is ignored, green past the
            // outer deadzone, where it already counts as full lock.
            if let dz {
                wheelArc(from: -Double(dz.left) * lock, to: Double(dz.right) * lock, rim: rim, d: d)
                    .stroke(Color.red.opacity(0.35), lineWidth: rim)
                if dz.outerRight < 0.99, Double(dz.outerRight) * lock < 180 {
                    wheelArc(from: Double(dz.outerRight) * lock, to: min(180, lock), rim: rim, d: d)
                        .stroke(Color.green.opacity(0.35), lineWidth: rim)
                }
                if dz.outerLeft < 0.99, Double(dz.outerLeft) * lock < 180 {
                    wheelArc(from: -min(180, lock), to: -Double(dz.outerLeft) * lock, rim: rim, d: d)
                        .stroke(Color.green.opacity(0.35), lineWidth: rim)
                }
            }
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(3, d * 0.03), height: d * 0.12)
                .offset(y: -d / 2 + d * 0.06)
                .rotationEffect(.degrees(angle))
            Text(reading)
                .font(.system(size: max(9, min(13, d * 0.05)), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(v == 0 ? .secondary : .primary)
                .offset(y: -d / 2 + d * 0.17)
        }
        .frame(width: d, height: d)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(c, "Wheel"))
        .accessibilityValue(reading)
    }

    /// An arc along the middle of a wheel's rim, in degrees from the top
    /// (clockwise positive), each end held within half a turn.
    private func wheelArc(from a: Double, to b: Double, rim: CGFloat, d: CGFloat) -> Path {
        let lo = max(-180, min(a, b)), hi = min(180, max(a, b))
        var p = Path()
        guard hi > lo else { return p }
        p.addArc(center: CGPoint(x: d / 2, y: d / 2), radius: d / 2 - rim / 2,
                 startAngle: .degrees(lo - 90), endAngle: .degrees(hi - 90), clockwise: false)
        return p
    }

    private func analogBar(_ c: PlacedControl, size: CGSize) -> some View {
        let axis = c.inputs.axes.first?.index
        // No reading (nothing connected) draws empty, not half full.
        let reading = axis.flatMap { state.axes[$0] }
        let v = reading.map(CGFloat.init) ?? 0
        let unipolar = c.inputs.axes.first?.unipolar ?? true
        let level = reading == nil ? 0 : (unipolar ? min(1, max(0, v)) : (v + 1) / 2)
        let shape = shapePath(c.shape, in: size)
        let name = legend(c).text
        let dz = deadzone(c)
        let marks: [CGFloat] = unipolar
            ? (dz.map { $0.thresholds } ?? axis.flatMap(threshold).map { [$0] } ?? []).map { CGFloat(min(1, max(0, $0))) }
            : []
        func clamp(_ v: Float) -> CGFloat { CGFloat(min(1, max(0, v))) }
        return ZStack(alignment: .bottom) {
            shape.fill(Color.secondary.opacity(0.15))
            shape.fill(Color.accentColor.gradient).mask(alignment: .bottom) { Rectangle().frame(height: size.height * level) }
            // The calibration sheet's bands: red where the control is
            // ignored (from rest on a pedal, around the middle on a slider
            // that runs both ways), green where it already counts as full.
            if let dz {
                if unipolar {
                    shape.fill(Color.red.opacity(0.22))
                        .mask(alignment: .bottom) { Rectangle().frame(height: size.height * clamp(dz.thresholds.min() ?? dz.right)) }
                    if dz.outerRight < 0.99 {
                        shape.fill(Color.green.opacity(0.22))
                            .mask(alignment: .top) { Rectangle().frame(height: size.height * (1 - clamp(dz.outerRight))) }
                    }
                } else {
                    shape.fill(Color.red.opacity(0.22))
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: size.height * (clamp(dz.left) + clamp(dz.right)) / 2)
                                .offset(y: -size.height * (1 - clamp(dz.left)) / 2)
                        }
                    if dz.outerRight < 0.99 {
                        shape.fill(Color.green.opacity(0.22))
                            .mask(alignment: .top) { Rectangle().frame(height: size.height * (1 - clamp(dz.outerRight)) / 2) }
                    }
                    if dz.outerLeft < 0.99 {
                        shape.fill(Color.green.opacity(0.22))
                            .mask(alignment: .bottom) { Rectangle().frame(height: size.height * (1 - clamp(dz.outerLeft)) / 2) }
                    }
                }
            }
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Rectangle().fill(Color.orange.opacity(0.7)).frame(height: 1)
                    .offset(y: -size.height * mark)
            }
            shape.stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            // What it is (Gas, Brake, Throttle), and how far it is pressed.
            VStack(spacing: 1) {
                if let name {
                    Text(name).font(.system(size: max(7, min(11, size.width * 0.2)), weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                if reading != nil, size.height > 34 {
                    Text("\(Int((level * 100).rounded()))%")
                        .font(.system(size: max(7, min(10, size.width * 0.17)), design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(level > 0.02 ? .primary : .secondary)
            .padding(2)
            .frame(maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(c, "Slider"))
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func port(_ c: PlacedControl, size: CGSize) -> some View {
        ZStack {
            shapePath(c.shape, in: size)
                .stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            if let text = c.printed {
                Text(text).font(.system(size: max(6, min(9, size.height * 0.5)))).foregroundStyle(.hint)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private func notReported(_ c: PlacedControl, size: CGSize) -> some View {
        let shape = shapePath(c.shape, in: size)
        return ZStack {
            shape.stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            if let symbol = legend(c).symbol {
                Image(systemName: symbol).font(.system(size: max(7, min(11, size.height * 0.45)))).foregroundStyle(.hint)
            } else if let text = legend(c).text {
                Text(text).font(.system(size: max(7, min(11, size.height * 0.4)))).foregroundStyle(.hint)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .opacity(0.6)
        .frame(width: size.width, height: size.height)
        .accessibilityLabel("\(spoken(c, "Control")), not reported to the Mac")
    }
}

extension ControllerCanvas {
    /// A two-axis control's deadzones as the calibration sheet draws a
    /// stick's: the inner deadzone a red ring, lightly filled, the outer
    /// one (when set) a green ring. `travel` is full travel each way.
    /// Always a true circle: where rows differ by direction, the ring is
    /// where the control first does something (the smallest inner value)
    /// and first counts as fully pushed (the smallest outer value); the
    /// tooltip names each direction's value.
    fileprivate func deadzoneRings(_ dz: CanvasDeadzone, travel: CGRect, fill: Bool = true, lines: Bool = true) -> some View {
        let r = min(dz.right, dz.left, dz.down, dz.up)
        let inner = Self.deadzonePath(in: travel, right: r, left: r, down: r, up: r)
        let o = min(dz.outerRight, dz.outerLeft, dz.outerDown, dz.outerUp)
        return ZStack {
            if fill { inner.fill(Color.red.opacity(0.08)) }
            if lines { inner.stroke(Color.red.opacity(0.5), lineWidth: 1) }
            if lines && dz.hasOuter {
                Self.deadzonePath(in: travel, right: o, left: o, down: o, up: o)
                    .stroke(Color.green.opacity(0.5), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A ring through each side's deadzone: a circle when they are equal,
    /// else four quarter ellipses meeting on the axes.
    static func deadzonePath(in r: CGRect, right: Float, left: Float, down: Float, up: Float) -> Path {
        func clamp(_ v: Float) -> CGFloat { CGFloat(min(1, max(0, v))) }
        let rr = clamp(right) * r.width / 2, rl = clamp(left) * r.width / 2
        let rd = clamp(down) * r.height / 2, ru = clamp(up) * r.height / 2
        var p = Path()
        let steps = 96
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            let c = CGFloat(cos(t)), s = CGFloat(sin(t))
            let pt = CGPoint(x: r.midX + (c >= 0 ? rr : rl) * c, y: r.midY + (s >= 0 ? rd : ru) * s)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// The deadzones a Live Visualizer panel's rows set on one control, as
/// fractions of full travel, for the drawing to mark the way the deadzone
/// calibration sheet does.
struct CanvasDeadzone: Equatable {
    /// The inner deadzone each way: x positive (right), x negative (left),
    /// y positive (down), y negative (up). A one-way control (a trigger, a
    /// pedal) uses `right`; a one-axis control that runs both ways from
    /// rest (a wheel, a slider) `right` and `left`.
    var right: Float = 0, left: Float = 0, down: Float = 0, up: Float = 0
    /// The outer deadzone each way: past it the control counts as fully
    /// pushed. 1 when no row sets one.
    var outerRight: Float = 1, outerLeft: Float = 1, outerDown: Float = 1, outerUp: Float = 1
    /// On a one-way control, where each row starts to count, smallest
    /// first: the red band reaches the first, an orange line marks each.
    var thresholds: [Float] = []
    /// Which rows set it and to what, for the tooltip and VoiceOver.
    var help: String = ""

    var hasOuter: Bool { min(outerRight, outerLeft, outerDown, outerUp) < 0.99 }
}

extension ControlInputs {
    /// The serialized inputs a control's inspector lists.
    func inspectEvents() -> [InputEvent] {
        var out: [InputEvent] = []
        for b in allButtons { out.append(.button(b)) }
        for a in axes {
            switch a.role {
            case .analog:
                out.append(.axis(a.index, direction: .positive))
                if !a.unipolar { out.append(.axis(a.index, direction: .negative)) }
            case .x, .y:
                out.append(.axis(a.index, direction: .positive))
                out.append(.axis(a.index, direction: .negative))
            }
        }
        if let h = hat {
            for d in HatDirection.allCases where hatDirection == nil || hatDirection == d { out.append(.hat(h, direction: d)) }
        }
        if let p = pressure { out.append(.axis(p, direction: .positive)) }
        return out
    }
}

/// Caption placement for the controller drawing: each caption takes the
/// first side, of its preferred one and then the others, where it stays on
/// the canvas and clear of every control and of every caption placed before
/// it; a long one is shortened to fit; one that fits nowhere is left off the
/// drawing (the control's popover and VoiceOver still say it).
/// Text sizes for the key, measured once.
enum CaptionLayout {
    static func fontSize(forWidth w: CGFloat) -> CGFloat { max(8.5, min(10.5, w * 0.017)) }

    nonisolated(unsafe) private static var widths: [String: CGFloat] = [:]
    /// The text's drawn width at that size, remembered.
    static func measure(_ text: String, fontSize: CGFloat) -> CGFloat {
        let key = "\(fontSize)|\(text)"
        if let w = widths[key] { return w }
        let w = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width) + 2
        if widths.count > 2000 { widths.removeAll() }
        widths[key] = w
        return w
    }
}

#if DEBUG
extension ControllerCanvas {
    /// What is wrong with the key at a panel width, worked out as the view
    /// lays it out: a line that runs under another control, captions closer
    /// than a line apart, a caption cut short. Empty when the key is clean.
    /// KeyLayoutTests runs it for every layout, variant and common width.
    func keyProblems(width w: CGFloat) -> [String] {
        let m = metrics
        guard m.keyed else { return [] }
        let kf = m.kf, bands = m.bands
        let laid = (tops: m.tops, total: m.total)
        let entries = keyEntries(bands: bands, tops: laid.tops, width: w, height: w * m.total, key: kf)
        var all: [(id: String, bounds: CGRect, obstacle: Obstacle)] = []
        for (n, b) in bands.enumerated() {
            for c in b.controls {
                let frame = controlFrame(c, band: b, top: laid.tops[n], width: w)
                all.append((c.id, Self.drawnBounds(c, frame), Self.obstacle(c, frame: frame)))
            }
        }
        let tag = "\(layout.id.rawValue)\(variant.map { ".\($0)" } ?? "") at \(Int(w)):"
        let fs = CaptionLayout.fontSize(forWidth: w)
        var out: [String] = []
        for e in entries {
            guard let ownEntry = all.first(where: { $0.id == e.id }) else { continue }
            let own = ownEntry.bounds
            // The line must end on the control's outline, not in space beside it.
            let gap: CGFloat = {
                let o = ownEntry.obstacle, a = e.anchor
                if let (p, q, r) = o.axis { return Self.distance(a, a, p, q) - r }
                if o.round {
                    let rx = o.rect.width / 2, ry = o.rect.height / 2
                    guard rx > 0, ry > 0 else { return 0 }
                    let d = hypot((a.x - o.rect.midX) / rx, (a.y - o.rect.midY) / ry)
                    return (d - 1) * min(rx, ry)
                }
                let dx = max(o.rect.minX - a.x, 0, a.x - o.rect.maxX), dy = max(o.rect.minY - a.y, 0, a.y - o.rect.maxY)
                return hypot(dx, dy)
            }()
            if gap > 3 { out.append("\(tag) the line to \(e.id) ends \(Int(gap)) points short of it") }
            let elbow = CGPoint(x: e.left ? (kf + keyGap * 0.5) * w : w - (kf + keyGap * 0.5) * w, y: e.y)
            for other in all where other.id != e.id && !other.bounds.contains(own) && !own.contains(other.bounds) {
                let o = other.obstacle
                let points = [elbow] + e.bends + [e.anchor]
                let crosses = zip(points, points.dropFirst()).contains { Self.segment($0.0, $0.1, hits: o, margin: -1) }
                if crosses {
                    out.append("\(tag) the line to \(e.id) runs under \(other.id)")
                }
            }
            // Two lines hold about twice the column, less what wrapping at
            // word breaks loses.
            if CaptionLayout.measure(e.text, fontSize: fs) > (kf * w - 4) * (e.lines == 2 ? 1.8 : 1) {
                out.append("\(tag) the caption for \(e.id) is cut short: \"\(e.text)\"")
            }
        }
        // No two lines cross or touch.
        for (a, b) in Self.crossingPairs(entries, width: w, key: kf, gap: keyGap) {
            out.append("\(tag) the lines to \(a) and \(b) cross")
        }
        for side in [true, false] {
            let column = entries.filter { $0.left == side }.sorted { $0.y < $1.y }
            for (a, b) in zip(column, column.dropFirst()) where b.y - a.y < fs * 1.15 * CGFloat(a.lines + b.lines) / 2 {
                out.append("\(tag) the captions for \(a.id) and \(b.id) overlap at \(Int(a.y)) and \(Int(b.y))")
            }
        }
        // Every control stays between the key columns, clear of the captions.
        for (n, b) in bands.enumerated() {
            for c in b.controls {
                let f = Self.drawnBounds(c, controlFrame(c, band: b, top: laid.tops[n], width: w))
                let edge = (kf + keyGap * 0.5) * w + 2
                if f.minX < edge || f.maxX > w - edge {
                    out.append("\(tag) \(c.id) reaches into the key column")
                }
            }
        }
        // A pill as wide as its word must not run into any other control.
        for (n, b) in bands.enumerated() {
            for c in b.controls where pillWord(c) != nil {
                let pill = controlFrame(c, band: b, top: laid.tops[n], width: w)
                for other in all where other.id != c.id && !other.bounds.contains(pill) && !pill.contains(other.bounds) {
                    if other.bounds.insetBy(dx: 0.5, dy: 0.5).intersects(pill) {
                        out.append("\(tag) the \(c.id) pill runs into \(other.id)")
                    }
                }
            }
        }
        return out
    }
}
#endif

#if DEBUG
extension ControllerCanvas {
    /// The key's geometry at a width, one line per entry, for debugging.
    func keyDump(width w: CGFloat) -> String {
        let m = metrics
        guard m.keyed else { return "no key" }
        let kf = m.kf, bands = m.bands
        let laid = (tops: m.tops, total: m.total)
        let total = m.total
        let entries = keyEntries(bands: bands, tops: laid.tops, width: w, height: w * total, key: kf)
        var lines = ["kf \(kf) height \(w * total)"]
        for (n, b) in bands.enumerated() {
            for c in b.controls {
                let r = Self.drawnBounds(c, controlFrame(c, band: b, top: laid.tops[n], width: w))
                lines.append("control \(c.id) \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))")
            }
        }
        for e in entries { lines.append("entry \(e.id) \(e.left ? "L" : "R") y \(Int(e.y)) anchor \(Int(e.anchor.x)),\(Int(e.anchor.y))") }
        return lines.joined(separator: "\n")
    }
}
#endif

#if DEBUG
extension ControllerCanvas {
    /// The key column's width and the longest entry, for review.
    var keyWidthReport: String {
        let keyed = referenceBands, laid = stack(keyed)
        var texts: [String] = []
        for (n, b) in keyed.enumerated() {
            for c in b.controls {
                if let t = keyText(c, size: controlFrame(c, band: b, top: laid.tops[n], width: 560).size) { texts.append(t) }
            }
        }
        let widest = texts.max { CaptionLayout.measure($0, fontSize: 8.5) < CaptionLayout.measure($1, fontSize: 8.5) } ?? ""
        return String(format: "%.3f", keyFraction) + " \(layout.id.rawValue) \"\(widest)\""
    }
}
#endif
