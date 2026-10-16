import Foundation
import Combine

/// Stores user-defined zones, rectangles or ring sectors, on a joystick stick's X/Y
/// plane. Lets the user bind diagonal / quadrant deflections (e.g.
/// "stick pushed to upper-right corner") as a single binding instead
/// of stitching together separate axis-positive and axis-negative
/// half-axis bindings.
///
/// Coordinate space:
///   - Internal storage uses 0...1 on both axes (reusing the existing
///     `TouchpadRegion` model so the UI can share the same canvas
///     widget).
///   - A stick reports X and Y in -1...1 from the controller's axes.
///     At evaluation time we map -1 → 0, +1 → 1, then check
///     containment. The "upper-right quadrant" of the stick is
///     therefore stored as `minX: 0.5, maxX: 1, minY: 0, maxY: 0.5`
///     (Y=0 is top, matching the touchpad convention).
///
/// Regions are global, not per-controller. A given controller slot
/// just has "left stick" (0) and "right stick" (1) which share the
/// same region set so a binding portable across controllers works
/// the same on every gamepad with a comparable stick layout.
@MainActor
final class StickRegionService: ObservableObject {

    static let shared = StickRegionService()

    /// All regions defined, keyed by stick index (0 = left, 1 = right).
    @Published private(set) var regionsByStick: [Int: [TouchpadRegion]] = [0: [], 1: []]

    /// Flat lookup table maintained alongside `regionsByStick` so
    /// `region(with:)` and `isRegionPressed(_:)` don't have to scan
    /// both stick buckets linearly on every poll frame. With M
    /// stick-region bindings × N regions defined the mapping engine
    /// would otherwise pay O(M x N) per tick at 120 Hz.
    private var lookupByID: [UUID: (region: TouchpadRegion, stickIndex: Int)] = [:]

    private static let storageKey = "InputConfig.stickRegions.v1"

    private init() {
        loadRegions()
        // loadRegions populates regionsByStick from disk; rebuild the
        // lookup index from that bulk-loaded state.
        rebuildLookup()
    }

    /// Rebuild called from CRUD methods when the bucket structure
    /// changes (load/delete paths). upsert maintains the index
    /// incrementally so we don't pay a rebuild on every save.

    private func rebuildLookup() {
        var table: [UUID: (region: TouchpadRegion, stickIndex: Int)] = [:]
        for (stick, list) in regionsByStick {
            for r in list {
                table[r.id] = (r, stick)
            }
        }
        lookupByID = table
    }

    // MARK: - CRUD

    func regions(forStick stickIndex: Int) -> [TouchpadRegion] {
        return regionsByStick[stickIndex] ?? []
    }

    func region(with id: UUID) -> (region: TouchpadRegion, stickIndex: Int)? {
        return lookupByID[id]
    }

    func upsert(_ region: TouchpadRegion, stickIndex: Int) {
        var list = regionsByStick[stickIndex] ?? []
        if let idx = list.firstIndex(where: { $0.id == region.id }) {
            list[idx] = region
        } else {
            list.append(region)
        }
        regionsByStick[stickIndex] = list
        lookupByID[region.id] = (region, stickIndex)
        persistRegions()
    }

    func delete(_ id: UUID) {
        for (stick, var list) in regionsByStick {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                list.remove(at: idx)
                regionsByStick[stick] = list
                lookupByID.removeValue(forKey: id)
                persistRegions()
                return
            }
        }
    }

    // MARK: - Hit testing

    /// True iff the stick at `stickIndex` for the given controller is
    /// currently deflected into the named region. The MappingEngine
    /// calls this each poll frame for `.stickRegion` inputs.
    ///
    /// `axes` is the slot's snapshot from `ControllerState.axes`:
    ///   stick 0 reads axes[0] (X) and axes[1] (Y)
    ///   stick 1 reads axes[2] (X) and axes[3] (Y)
    func isRegionPressed(_ id: UUID, axes: [Int: Float]) -> Bool {
        guard let (_, stickIndex) = self.region(with: id), !Self.isBandKey(stickIndex) else { return false }
        let xAxis = stickIndex == 1 ? 2 : 0
        let yAxis = stickIndex == 1 ? 3 : 1
        return isRegionPressed(id, x: axes[xAxis] ?? 0, y: axes[yAxis] ?? 0)
    }

    /// Same hit test, taking the two already-corrected stick values directly.
    /// The MappingEngine calls this per poll frame; the dictionary overload
    /// above forced it to clone the slot's whole axes dict just to override
    /// the two entries for deadzone / invert correction.
    func isRegionPressed(_ id: UUID, x: Float, y: Float) -> Bool {
        guard let (region, key) = self.region(with: id), !Self.isBandKey(key) else { return false }
        guard region.ring != nil || (region.maxX > region.minX && region.maxY > region.minY) else { return false }
        // Map from stick coords (-1...1) to region coords (0...1).
        // Y stays in the same convention as touchpad regions: 0 = top.
        let normX = (Double(x) + 1.0) / 2.0
        let normY = (Double(y) + 1.0) / 2.0
        // Far edges open, as on the touchpad: two zones sharing a border
        // (Upper left and Upper right with the stick straight up) are not
        // both pressed on it.
        return region.contains(normalizedX: normX, y: normY)
    }

    // MARK: - Travel bands

    /// Zones on one axis's travel (a trigger, a throttle, one direction of
    /// a stick) live under this key plus the axis number, beside the two
    /// sticks' plane zones.
    nonisolated static let bandKeyBase = 100

    nonisolated static func isBandKey(_ key: Int) -> Bool { key >= bandKeyBase }

    /// The stick (0, 1) or band key whose regions a direction row on this
    /// axis can wait for: the editor's menu and the engine read the same.
    nonisolated static func gateKey(forAxis a: Int) -> Int {
        (0...3).contains(a) ? (a <= 1 ? 0 : 1) : bandKeyBase + a
    }

    /// How far along its travel an axis reading is, 0 at the low end: a
    /// released trigger, a stick pushed left, a stick pushed down (the app
    /// reads stick Y with down positive, so Y is turned over here to put
    /// down at the bottom of the bar).
    nonisolated static func travelFraction(axis: Int, value: Float, oneWay: Bool) -> Double {
        let v = Double(value)
        let f: Double
        if oneWay { f = v }
        else if axis == 1 || axis == 3 { f = (1 - v) / 2 }
        else { f = (v + 1) / 2 }
        return f.isFinite ? min(1, max(0, f)) : 0
    }

    /// Whether an axis counts 0 to 1 rather than -1 to 1: the two triggers.
    nonisolated static func axisIsOneWay(_ axis: Int) -> Bool { axis == 4 || axis == 5 }

    /// The axis a band key reads, as the band lists name it.
    nonisolated static func axisDisplayName(_ axis: Int) -> String {
        ButtonNames.axisName(axis, family: .automatic) ?? String(localized: "Axis \(axis)")
    }

    /// What the low and high end of an axis's travel are, for the bar.
    nonisolated static func travelEnds(axis: Int) -> (low: String, high: String) {
        switch axis {
        case 4, 5: return (String(localized: "Released"), String(localized: "Pulled all the way"))
        case 0, 2: return (String(localized: "Left"), String(localized: "Right"))
        case 1, 3: return (String(localized: "Down"), String(localized: "Up"))
        default: return (String(localized: "Low end"), String(localized: "High end"))
        }
    }

    /// True while the axis reading is inside the band.
    func isBandPressed(_ id: UUID, fraction: Double) -> Bool {
        guard let (region, key) = self.region(with: id), Self.isBandKey(key),
              region.maxY > region.minY else { return false }
        return region.containsTravel(fraction)
    }

    // MARK: - Overlap with direction rows

    /// The numbers (1 based, in the group) of the direction rows on a zone
    /// row's stick or axis that the zone overlaps: where the stick can be
    /// inside the zone and past the row's deadzone the row's way.
    func directionRowsOverlapping(_ zoneRow: BindingModel, in rows: [BindingModel]) -> [Int] {
        guard let id = zoneRow.input.stickRegionID, let found = region(with: id) else { return [] }
        let key = found.stickIndex
        var out: [Int] = []
        for (i, row) in rows.enumerated() where row.input.type == .axis && row.id != zoneRow.id {
            let axis = row.input.index
            let t = Double(row.deadzone ?? 0.25)
            // The range the row's axis covers inside the zone, as the app
            // reads the axis (-1...1, stick Y down positive; 0...1 triggers).
            var lo: Double, hi: Double
            if Self.isBandKey(key) {
                guard axis == key - Self.bandKeyBase else { continue }
                let f0 = found.region.minY, f1 = found.region.maxY
                if Self.axisIsOneWay(axis) { lo = f0; hi = f1 }
                else if axis == 1 || axis == 3 { lo = 1 - 2 * f1; hi = 1 - 2 * f0 }
                else { lo = 2 * f0 - 1; hi = 2 * f1 - 1 }
            } else {
                let xAxis = key == 1 ? 2 : 0, yAxis = key == 1 ? 3 : 1
                guard axis == xAxis || axis == yAxis else { continue }
                let box = found.region.drawnBox
                if axis == xAxis { lo = box.minX * 2 - 1; hi = box.maxX * 2 - 1 }
                else { lo = box.minY * 2 - 1; hi = box.maxY * 2 - 1 }
            }
            if row.invertAxis == true { (lo, hi) = (-hi, -lo) }
            // A zone row with Invert reads the stick mirrored too.
            if zoneRow.invertAxis == true { (lo, hi) = (-hi, -lo) }
            let overlaps: Bool
            switch row.input.axisDirection {
            case .positive?: overlaps = hi > t
            case .negative?: overlaps = lo < -t
            case nil: overlaps = hi > t || lo < -t
            }
            if overlaps { out.append(i + 1) }
        }
        return out
    }

    /// For a direction row: the zone rows that take its stick or trigger
    /// over somewhere it fires, by number. Inside those zones it waits.
    func zoneRowsTakingOver(_ axisRow: BindingModel, in rows: [BindingModel]) -> [Int] {
        guard axisRow.input.type == .axis, let mine = rows.firstIndex(where: { $0.id == axisRow.id }) else { return [] }
        var out: [Int] = []
        for (i, row) in rows.enumerated() where row.input.type == .stickRegion && row.zoneSharesStick == false {
            if directionRowsOverlapping(row, in: rows).contains(mine + 1) { out.append(i + 1) }
        }
        return out
    }

    /// The other zone rows that fire together with this one somewhere, by
    /// number: two zones on one stick that overlap, or a band on one of the
    /// stick's axes that crosses one of its zones. Each row is tested as the
    /// engine fires it, with its Invert and its deadzone. Rows on the same
    /// zone are left out, as two rows on one button.
    func zoneRowsOverlapping(_ zoneRow: BindingModel, in rows: [BindingModel]) -> [Int] {
        guard let id = zoneRow.input.stickRegionID, let found = region(with: id) else { return [] }
        let mine = ZoneTest(row: zoneRow, region: found.region, key: found.stickIndex)
        var out: [Int] = []
        for (i, row) in rows.enumerated() where row.input.type == .stickRegion && row.id != zoneRow.id {
            guard let otherID = row.input.stickRegionID, otherID != id, let other = region(with: otherID) else { continue }
            if Self.fireTogether(mine, ZoneTest(row: row, region: other.region, key: other.stickIndex)) { out.append(i + 1) }
        }
        return out
    }

    /// One zone row as the overlap test needs it.
    struct ZoneTest: Hashable {
        let region: TouchpadRegion
        let key: Int
        let invert: Bool
        let deadzone: Double

        init(row: BindingModel, region: TouchpadRegion, key: Int) {
            self.region = region
            self.key = key
            invert = row.invertAxis == true
            deadzone = Double(row.deadzone ?? 0.25)
        }

        /// The stick (0 left, 1 right) this zone is on, a band on one of a
        /// stick's axes included; nil for a trigger or another axis.
        var stick: Int? {
            if !StickRegionService.isBandKey(key) { return key }
            let axis = key - StickRegionService.bandKeyBase
            return (0...3).contains(axis) ? axis / 2 : nil
        }

        /// The box this zone fires inside, in stick space (-1...1 on each
        /// axis, as `fires` reads it, so Invert is applied): a rectangle's
        /// own bounds, or the circle of a ring's outer edge, which is all
        /// `RingSector.contains` can accept. Nil for a band.
        var stickBox: (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
            if StickRegionService.isBandKey(key) { return nil }
            if let ring = region.ring {
                let r = min(1, max(0, ring.outer))
                return ((-r)...r, (-r)...r)
            }
            func span(_ lo: Double, _ hi: Double) -> ClosedRange<Double> {
                let a = min(lo, hi) * 2 - 1, b = max(lo, hi) * 2 - 1
                return invert ? (-b)...(-a) : a...b
            }
            return (span(region.minX, region.maxX), span(region.minY, region.maxY))
        }

        /// Whether the row fires with its stick at x, y (-1...1, y down).
        func fires(x: Double, y: Double) -> Bool {
            if StickRegionService.isBandKey(key) {
                let axis = key - StickRegionService.bandKeyBase
                let v = axis % 2 == 0 ? x : y
                return firesOnAxis(v, axis: axis, oneWay: false)
            }
            guard hypot(x, y) >= deadzone else { return false }
            let (sx, sy) = invert ? (-x, -y) : (x, y)
            return region.contains(normalizedX: (sx + 1) / 2, y: (sy + 1) / 2)
        }

        /// Whether a band row fires at this reading of its axis.
        func firesOnAxis(_ v: Double, axis: Int, oneWay: Bool) -> Bool {
            var f = StickRegionService.travelFraction(axis: axis, value: Float(v), oneWay: oneWay)
            if invert { f = 1 - f }
            if !oneWay, abs(v) < deadzone,
               region.minY < 0.5 - deadzone / 2 || region.maxY > 0.5 + deadzone / 2 { return false }
            return region.containsTravel(f)
        }
    }

    /// Results of `fireTogether`, which samples finely: rows are drawn
    /// whenever the editor redraws, and zones change only when edited.
    private static var overlapCache: [[ZoneTest]: Bool] = [:]

    /// Whether two zone rows fire together at any reading. Bands on one
    /// axis are walked along that axis; zones on a stick, and bands on its
    /// axes, are sampled across the stick a hundredth of its travel apart.
    static func fireTogether(_ a: ZoneTest, _ b: ZoneTest) -> Bool {
        // The test is symmetric, and every row asks about every other row,
        // so (a, b) and (b, a) share one entry; keyed in call order, each
        // pair was sampled twice.
        let cacheKey = a.hashValue <= b.hashValue ? [a, b] : [b, a]
        if let hit = overlapCache[cacheKey] { return hit }
        var result = false
        if isBandKey(a.key), a.key == b.key {
            let axis = a.key - bandKeyBase
            let oneWay = axisIsOneWay(axis)
            for i in 0...1000 {
                let t = Double(i) / 1000
                let v = oneWay ? t : t * 2 - 1
                if a.firesOnAxis(v, axis: axis, oneWay: oneWay) && b.firesOnAxis(v, axis: axis, oneWay: oneWay) { result = true; break }
            }
        } else if let stick = a.stick, stick == b.stick {
            // Two zones on the stick's plane fire only inside their own
            // boxes (a ring sector inside its bounding box), so only the
            // samples inside both boxes can fire both: none when the boxes
            // do not meet, which is most pairs of a grid. The full 201 x 201
            // walk, 40,401 samples a pair, stays for a band crossing a zone.
            // Measured on the 4 x 4 grid of 16 zones the editor opens with:
            // 240 ordered pairs x 40,401 = 9.7 million samples before; 120
            // pairs, 84 of them rejected by their boxes and the 36 that touch
            // walking a shared edge or corner of up to 51 samples, after.
            var xs: ClosedRange<Int>? = 0...200, ys: ClosedRange<Int>? = 0...200
            if let box = a.stickBox, let other = b.stickBox {
                xs = Self.sampleRange(box.x, other.x)
                ys = Self.sampleRange(box.y, other.y)
            }
            if let xs, let ys {
                outer: for i in xs {
                    let x = Double(i) / 100 - 1
                    for j in ys {
                        let y = Double(j) / 100 - 1
                        #if DEBUG
                        debugOverlapSamples &+= 1
                        #endif
                        if a.fires(x: x, y: y) && b.fires(x: x, y: y) { result = true; break outer }
                    }
                }
            }
        }
        if overlapCache.count > 2000 { overlapCache.removeAll() }
        overlapCache[cacheKey] = result
        return result
    }

    #if DEBUG
    /// Points sampled by `fireTogether` since the counter was last reset;
    /// the tests count the work a zone grid costs.
    static var debugOverlapSamples = 0
    static func debugResetOverlapCache() { overlapCache.removeAll(); debugOverlapSamples = 0 }
    #endif

    /// The sample indices (x = i / 100 - 1) inside both of two stick-space
    /// spans, or nil when the spans do not meet. A hundredth wider each way,
    /// so a shared edge that sits between two samples is still walked.
    private static func sampleRange(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> ClosedRange<Int>? {
        let lo = max(a.lowerBound, b.lowerBound), hi = min(a.upperBound, b.upperBound)
        guard lo <= hi else { return nil }
        let first = max(0, Int(((lo + 1) * 100).rounded(.down)) - 1)
        let last = min(200, Int(((hi + 1) * 100).rounded(.up)) + 1)
        return first <= last ? first...last : nil
    }

    // MARK: - Persistence

    private struct PersistedRoot: Codable {
        var byStick: [String: [TouchpadRegion]]
    }

    private func loadRegions() {
        // The working set starts empty; a preset fills it when it runs or
        // is edited. (Before 1.5 this read an app-wide list from defaults.)
        regionsByStick = [0: [], 1: []]
    }

    /// Regions belong to presets (`Preset.stickRegions`); the preset
    /// captures the working set on Save, so nothing is written here.
    private func persistRegions() { }

    /// Make these the regions in play.
    func load(_ byStick: [Int: [TouchpadRegion]]) {
        var rebuilt: [Int: [TouchpadRegion]] = [0: [], 1: []]
        for (i, list) in byStick where i == 0 || i == 1 || (Self.isBandKey(i) && i < Self.bandKeyBase + 64) {
            rebuilt[i] = list
        }
        regionsByStick = rebuilt
        rebuildLookup()
    }

    /// Regions the app kept app-wide before 1.5, for the migration.
    static func legacyAppWideRegions() -> [Int: [TouchpadRegion]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(PersistedRoot.self, from: data) else { return [:] }
        var out: [Int: [TouchpadRegion]] = [:]
        for (key, list) in decoded.byStick { if let i = Int(key) { out[i] = list } }
        return out
    }
}
