import Foundation
import Combine

/// Stores user-defined rectangular zones on a joystick stick's X/Y
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
    /// would otherwise pay O(M·N) per tick at 120 Hz.
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
        guard let (_, stickIndex) = self.region(with: id) else { return false }
        let xAxis = stickIndex == 1 ? 2 : 0
        let yAxis = stickIndex == 1 ? 3 : 1
        return isRegionPressed(id, x: axes[xAxis] ?? 0, y: axes[yAxis] ?? 0)
    }

    /// Same hit test, taking the two already-corrected stick values directly.
    /// The MappingEngine calls this per poll frame; the dictionary overload
    /// above forced it to clone the slot's whole axes dict just to override
    /// the two entries for deadzone / invert correction.
    func isRegionPressed(_ id: UUID, x: Float, y: Float) -> Bool {
        guard let (region, _) = self.region(with: id) else { return false }
        guard region.maxX > region.minX && region.maxY > region.minY else { return false }
        // Map from stick coords (-1...1) to region coords (0...1).
        // Y stays in the same convention as touchpad regions: 0 = top.
        let normX = (Double(x) + 1.0) / 2.0
        let normY = (Double(y) + 1.0) / 2.0
        return normX >= region.minX && normX <= region.maxX
            && normY >= region.minY && normY <= region.maxY
    }

    // MARK: - Persistence

    private struct PersistedRoot: Codable {
        var byStick: [String: [TouchpadRegion]]
    }

    private func loadRegions() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(PersistedRoot.self, from: data) else {
            return
        }
        var rebuilt: [Int: [TouchpadRegion]] = [0: [], 1: []]
        for (key, list) in decoded.byStick {
            if let idx = Int(key) {
                rebuilt[idx] = list
            }
        }
        regionsByStick = rebuilt
    }

    private func persistRegions() {
        var keyed: [String: [TouchpadRegion]] = [:]
        for (idx, list) in regionsByStick {
            keyed["\(idx)"] = list
        }
        let root = PersistedRoot(byStick: keyed)
        if let data = try? JSONEncoder().encode(root) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
