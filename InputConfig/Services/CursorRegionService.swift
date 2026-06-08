import Foundation
import AppKit

/// Maintains a set of user-defined screen regions for **cursor-position
/// based** bindings. A `.cursorRegion` input fires while the mouse
/// cursor is inside the named rectangle.
///
/// ## Why this exists separately from TouchpadService
///
/// `TouchpadService` reads per-finger HID positions from a DualSense /
/// DualShock 4 trackpad. The Mac built-in trackpad doesn't expose per-
/// finger data through public APIs, so we approximate the same workflow
/// using the system cursor position (which IS observable via the
/// existing `CGEventTap` in `ExternalInputDeviceService`).
///
/// Same rectangle model (`TouchpadRegion`) is reused so the calibration
/// UI and the binding editor can share most of their code. The only
/// behavioural difference is the data source: where TouchpadService
/// asks "is finger 0 inside Region X right now?" this service asks
/// "is the cursor inside Region X right now?"
@MainActor
final class CursorRegionService: ObservableObject {
    static let shared = CursorRegionService()

    @Published private(set) var regions: [TouchpadRegion] = []

    /// Normalised cursor position in [0, 1] × [0, 1] across the *primary*
    /// display. Updated whenever a `.mouseMoved` CGEvent arrives via
    /// `ExternalInputDeviceService`. (0, 0) is top-left.
    @Published private(set) var cursorNormalized: CGPoint = .zero

    private static let regionsKey = "InputConfig.cursorRegions.v1"

    /// Ref-counted poll timer. Cursor position used to be fed by the
    /// system `CGEventTap` in the old ExternalInputDeviceService, but
    /// that tap required the Input Monitoring / Accessibility permission
    /// and was removed for App Store compliance. We now sample
    /// `NSEvent.mouseLocation` directly, which needs **no permission**
    /// at all - it just reports the global cursor position. The timer
    /// only runs while at least one consumer is tracking (the mapping
    /// engine while a cursor-region preset is active, or the regions
    /// editor while open), so an idle app does no polling.
    private var pollTimer: Timer?
    private var trackingRetainCount = 0

    private init() {
        loadRegions()
        // Seed cursor position from the current mouse location so a binding
        // can fire from the very first poll, before tracking starts.
        // NSEvent.mouseLocation is screen coords (origin bottom-left).
        updateFromScreenPoint(NSEvent.mouseLocation, originIsBottomLeft: true)
    }

    // MARK: - Cursor polling (no permission required)

    /// Begin sampling the cursor position. Ref-counted so multiple
    /// consumers (engine + editor) can request tracking independently.
    /// Polls at 60 Hz, which is plenty for region hit-testing and far
    /// cheaper than the old per-motion-event tap.
    func beginTracking() {
        trackingRetainCount += 1
        guard pollTimer == nil else { return }
        // Sample immediately so a region can fire on the first frame.
        updateFromScreenPoint(NSEvent.mouseLocation, originIsBottomLeft: true)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateFromScreenPoint(NSEvent.mouseLocation, originIsBottomLeft: true)
        }
        // .common so it keeps firing during menu tracking / scrolling.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Release one tracking request. Stops polling when the last
    /// consumer ends tracking.
    func endTracking() {
        trackingRetainCount = max(0, trackingRetainCount - 1)
        guard trackingRetainCount == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Region CRUD

    func allRegions() -> [TouchpadRegion] { regions }

    func region(with id: UUID) -> TouchpadRegion? {
        regions.first(where: { $0.id == id })
    }

    func upsert(_ region: TouchpadRegion) {
        if let idx = regions.firstIndex(where: { $0.id == region.id }) {
            regions[idx] = region
        } else {
            regions.append(region)
        }
        persistRegions()
    }

    func deleteRegion(_ id: UUID) {
        regions.removeAll { $0.id == id }
        persistRegions()
    }

    // MARK: - Hit testing

    /// True iff the cursor is currently inside the region with the given
    /// ID. Used by `MappingEngine.checkInput` for `.cursorRegion` inputs.
    ///
    /// Zero-width / zero-height regions are treated as never-pressed.
    /// Otherwise the cursor sitting exactly on the line of a 0-area
    /// "region" would flicker the binding on every sub-pixel jitter,
    /// which is confusing UX rather than useful behaviour.
    func isRegionPressed(_ id: UUID) -> Bool {
        guard let r = region(with: id) else { return false }
        guard r.maxX > r.minX && r.maxY > r.minY else { return false }
        let p = cursorNormalized
        return p.x >= CGFloat(r.minX) && p.x <= CGFloat(r.maxX)
            && p.y >= CGFloat(r.minY) && p.y <= CGFloat(r.maxY)
    }

    // MARK: - Cursor tracking

    /// Update from a CGEvent location (`event.location`) which is in
    /// **top-left-origin** screen coordinates already.
    func updateFromCGEventLocation(_ point: CGPoint) {
        updateFromScreenPoint(point, originIsBottomLeft: false)
    }

    /// Update from an NSEvent / NSScreen point (`NSEvent.mouseLocation`)
    /// which is in **bottom-left-origin** screen coordinates.
    ///
    /// Multi-display handling: the cursor lives in a single virtual
    /// coordinate space spanning every connected NSScreen. We look up
    /// which screen actually contains the point and normalise against
    /// THAT screen's frame, so a cursor on a secondary display still
    /// matches regions drawn at the user's primary-display
    /// proportions. (Previously we always normalised against
    /// NSScreen.main, so cursor regions silently failed on secondary
    /// monitors.) HiDPI: NSScreen.frame is already in points - same
    /// space as the NSEvent / CGEvent location - so no extra scaling
    /// is needed.
    private func updateFromScreenPoint(_ point: CGPoint, originIsBottomLeft: Bool) {
        // Pick the screen whose frame contains the cursor point. Fall
        // back to NSScreen.main so we never crash on display teardown.
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
        guard let screen = screen else { return }
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let nx = (point.x - frame.minX) / frame.width
        let nyFromTop: CGFloat
        if originIsBottomLeft {
            nyFromTop = 1.0 - ((point.y - frame.minY) / frame.height)
        } else {
            nyFromTop = (point.y - frame.minY) / frame.height
        }
        // Clamp to [0, 1] so regions defined exactly at the screen edge
        // still match when the cursor is parked there.
        let clamped = CGPoint(x: min(max(nx, 0), 1),
                              y: min(max(nyFromTop, 0), 1))
        // Only publish a change when it actually moved; cursor events
        // arrive at hundreds of Hz and we don't want a SwiftUI render
        // storm for sub-pixel jitter.
        if abs(clamped.x - cursorNormalized.x) > 0.001
            || abs(clamped.y - cursorNormalized.y) > 0.001 {
            cursorNormalized = clamped
        }
    }

    // MARK: - Persistence

    private func loadRegions() {
        guard let data = UserDefaults.standard.data(forKey: Self.regionsKey),
              let decoded = try? JSONDecoder().decode([TouchpadRegion].self, from: data) else {
            return
        }
        regions = decoded
    }

    private func persistRegions() {
        if let data = try? JSONEncoder().encode(regions) {
            UserDefaults.standard.set(data, forKey: Self.regionsKey)
        }
    }
}
