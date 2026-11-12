import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Reads the color the screen shows at each of a preset's screen color
/// watches (`ScreenPixelWatch`) and says whether a `.screenPixel` row is
/// pressed.
///
/// Same shape as `CursorRegionService`: the watches are the preset's,
/// loaded on activation and captured back on save; sampling is ref-counted
/// and runs only while a preset with such rows runs or the Screen Colors
/// sheet is open. Each tick takes one capture per display covering its
/// watches, cuts a 3 by 3 point square around each watch's point from it
/// and averages that, so a single pixel of anti-aliasing or a one-point
/// drift never flips a row. (A capture per watch cost the same 44 ms and
/// replayd time whatever its size, and the process tops out near 37
/// captures a second: four watches already sampled below the rate.)
///
/// Reading the screen needs the Screen Recording permission. The service
/// never prompts: `ScreenRecordingPermission` asks from Settings and the
/// sheet, and a preset whose watches cannot be read says so once in the
/// activity log and reads them as not pressed.
@MainActor
final class ScreenPixelService: ObservableObject {
    static let shared = ScreenPixelService()

    @Published private(set) var watches: [ScreenPixelWatch] = []

    /// The last color read at each watch, sRGB 0 to 255, for the sheet's
    /// live readout and the row's state. Published only when the color
    /// changes; when it was read is kept apart in `sampledAt`.
    struct Sample: Equatable {
        var red: Int, green: Int, blue: Int
    }
    @Published private(set) var samples: [UUID: Sample] = [:]
    private var sampledAt: [UUID: TimeInterval] = [:]

    /// Samples per second while tracking. Ten is enough for a bar or a
    /// light and keeps the capture cost unnoticeable.
    static let rate: Double = 10

    private var timer: Timer?
    private var retainCount = 0
    /// Watches with a capture in flight, so a slow tick never queues more.
    private var inFlight: Set<UUID> = []
    /// Match mode: held while within tolerance. Change mode: pressed until
    /// this time after a change.
    /// Published for the sheet's spoken Pressed and Not pressed.
    @Published private(set) var pressed: Set<UUID> = []
    private var pulseUntil: [UUID: TimeInterval] = [:]
    /// Captures in a row that came back empty, per watch. Three let go of
    /// a held row: a lost display or permission otherwise kept its key
    /// down until the preset stopped.
    private var failedReads: [UUID: Int] = [:]
    /// Bumped when tracking ends: a capture still in flight then belongs to
    /// the run that ended, and its reading is dropped, not carried into the
    /// next start as the color a Change compares with.
    private var run = 0
    /// Watches whose display was said to be missing, once each.
    private var saidMissing: Set<UUID> = []

    private func noteFailedRead(_ id: UUID) {
        failedReads[id, default: 0] += 1
        guard failedReads[id, default: 0] >= 3 else { return }
        if pressed.contains(id) { pressed.remove(id) }
        pulseUntil[id] = nil
    }
    /// Change mode compares against the color of the previous sample.
    private var previous: [UUID: Sample] = [:]
    private var saidNoPermission = false
    /// The permission, asked of the system once a second rather than on
    /// every tick.
    private var hasPermission = false
    private var permissionCheckedAt: TimeInterval = 0

    /// Published, so the visualizer's list redraws when sampling starts
    /// or stops; follows `retainCount`.
    @Published private(set) var isTracking = false

    private init() {}

    // MARK: - The preset's watches

    func load(_ list: [ScreenPixelWatch]) {
        let new = list.prefix(ScreenPixelWatch.maxWatches).map { $0.clampedValues() }
        // A reload with the watch unchanged keeps what it read: a held Match
        // row stays held, and a Change does not skip a tick.
        let same = Set(new.filter { watches.contains($0) }.map(\.id))
        watches = new
        samples = samples.filter { same.contains($0.key) }
        sampledAt = sampledAt.filter { same.contains($0.key) }
        previous = previous.filter { same.contains($0.key) }
        pulseUntil = pulseUntil.filter { same.contains($0.key) }
        pressed.formIntersection(same)
    }

    func allWatches() -> [ScreenPixelWatch] { watches }

    func watch(with id: UUID) -> ScreenPixelWatch? { watches.first { $0.id == id } }

    func upsert(_ watch: ScreenPixelWatch) {
        let w = watch.clampedValues()
        if let i = watches.firstIndex(where: { $0.id == w.id }) {
            let was = watches[i]
            watches[i] = w
            // Another spot or mode: the last color was another point's, and
            // a Change fired on the edit itself.
            if was.display != w.display || was.x != w.x || was.y != w.y || was.mode != w.mode {
                samples[w.id] = nil; sampledAt[w.id] = nil; previous[w.id] = nil; pressed.remove(w.id); pulseUntil[w.id] = nil
            }
        } else if watches.count < ScreenPixelWatch.maxWatches {
            watches.append(w)
        }
    }

    func delete(_ id: UUID) {
        watches.removeAll { $0.id == id }
        samples[id] = nil; sampledAt[id] = nil; previous[id] = nil; pressed.remove(id); pulseUntil[id] = nil
    }

    /// The next palette slot, cycling like the region editors do.
    var nextColorIndex: Int { watches.count % 8 }

    // MARK: - Sampling

    func beginTracking() {
        retainCount += 1
        isTracking = retainCount > 0
        guard timer == nil else { return }
        saidNoPermission = false
        permissionCheckedAt = 0
        ScreenCapture.prepare()
        tick()
        let t = Timer(timeInterval: 1 / Self.rate, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func endTracking() {
        retainCount = max(0, retainCount - 1)
        isTracking = retainCount > 0
        guard retainCount == 0 else { return }
        timer?.invalidate(); timer = nil
        pressed = []; pulseUntil = [:]; previous = [:]; inFlight = []
        run &+= 1
        // The colors read are not kept for the rest of the run.
        samples = [:]
    }

    /// True while the watch's row should read as held. False when nothing
    /// samples (the last color would be stale) or the watch is unknown.
    func isPressed(_ id: UUID) -> Bool {
        guard timer != nil, let w = watch(with: id) else { return false }
        switch w.mode {
        case .match: return pressed.contains(id)
        case .change:
            guard let until = pulseUntil[id] else { return false }
            return ProcessInfo.processInfo.systemUptime < until
        }
    }

    /// How many Change presses each watch has made, for the sheet: a press
    /// is over before anything would draw it again.
    @Published private(set) var pulses: [UUID: Int] = [:]

    /// How long a Change press lasts: two engine polls at the slowest rate.
    static let pulseSeconds: TimeInterval = 0.12

    private func tick() {
        guard !watches.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - permissionCheckedAt >= 1 {
            hasPermission = ScreenRecordingPermission.hasAccess
            permissionCheckedAt = now
        }
        guard hasPermission else {
            // Every row reads as not pressed, as the log line says.
            if !pressed.isEmpty { pressed.removeAll() }
            pulseUntil.removeAll()
            if !saidNoPermission {
                saidNoPermission = true
                ActivityLog.shared.warning("Screen", "Screen color rows need Screen Recording allowed for InputConfig in System Settings, Privacy & Security; until then they read as not pressed. Quit and reopen InputConfig after allowing it")
            }
            return
        }
        let run = self.run
        // The watches free to read, by display, each as the pixels of its
        // square; one capture per display (per cluster, when they spread
        // wider than ScreenCapture.clusterCap) where each took its own.
        var batches: [CGDirectDisplayID: [Member]] = [:]
        var order: [CGDirectDisplayID] = []
        for w in watches where !inFlight.contains(w.id) {
            // Its display gone: read as failed now, as its own capture did.
            guard let p = Self.pixelRect(for: w) else { noteCapture(failedFor: w); continue }
            if batches[p.display] == nil { order.append(p.display) }
            batches[p.display, default: []].append(Member(watch: w, rect: p.rect, scale: p.scale))
        }
        for display in order {
            guard let members = batches[display], let scale = members.first?.scale else { continue }
            for cluster in ScreenCapture.clusters(of: members.map(\.rect)) {
                let group = cluster.members.map { members[$0] }
                for m in group { inFlight.insert(m.watch.id) }
                Self.sampleColors(of: group.map(\.rect), within: cluster.union, on: display, scale: scale) { [weak self] colors in
                    guard let self, self.run == run else { return }
                    for m in group { self.inFlight.remove(m.watch.id) }
                    self.apply(colors, to: group)
                }
            }
        }
    }

    /// A watch and the display pixels its square covers.
    private struct Member {
        var watch: ScreenPixelWatch
        var rect: CGRect
        var scale: CGFloat
    }

    /// One capture's colors, one per member in order (nil as a whole when
    /// the screen could not be read). Each watch is judged as its own
    /// capture judged it; `samples`, `pressed` and `pulses` are set once
    /// for the capture, so the sheet and the visualizer update once a
    /// tick, not once per watch.
    private func apply(_ colors: [(Int, Int, Int)?]?, to group: [Member]) {
        let now = ProcessInfo.processInfo.systemUptime
        var samples = self.samples, pressed = self.pressed, pulses = self.pulses
        var failed: [ScreenPixelWatch] = []
        for (i, m) in group.enumerated() {
            let w = m.watch
            // A capture that finishes after its watch was deleted or
            // changed (the editor closed with Don't Save, the spot
            // moved) would bring the old watch's state back.
            guard watch(with: w.id) == w else { continue }
            guard let (r, g, b) = colors?[i] ?? nil else { failed.append(w); continue }
            saidMissing.remove(w.id)
            failedReads[w.id] = nil
            let sample = Sample(red: r, green: g, blue: b)
            judge(sample, at: now, for: w, pressed: &pressed, pulses: &pulses)
            if samples[w.id] != sample { samples[w.id] = sample }
        }
        if self.samples != samples { self.samples = samples }
        if self.pressed != pressed { self.pressed = pressed }
        if self.pulses != pulses { self.pulses = pulses }
        // After the sets above: a third failed read lets go of `pressed`.
        for w in failed { noteCapture(failedFor: w) }
    }

    private func noteCapture(failedFor w: ScreenPixelWatch) {
        noteFailedRead(w.id)
        // Back on its display, a Change compares with nothing.
        if Self.screen(for: w) == nil {
            previous[w.id] = nil
            if saidMissing.insert(w.id).inserted {
                ActivityLog.shared.warning("Screen", "\(w.name) watches a display that is not connected; its rows read as not pressed until it is back")
            }
        }
    }

    private func judge(_ sample: Sample, at now: TimeInterval, for w: ScreenPixelWatch,
                       pressed: inout Set<UUID>, pulses: inout [UUID: Int]) {
        switch w.mode {
        case .match:
            let d = w.distance(toRed: sample.red, green: sample.green, blue: sample.blue)
            // A little hysteresis: a row lets go only once the color has
            // moved clearly past the tolerance, so a value at the edge
            // does not flutter.
            if pressed.contains(w.id) {
                if d > w.tolerance * 1.15 + 0.01 { pressed.remove(w.id) }
            } else if d <= w.tolerance {
                pressed.insert(w.id)
            }
        case .change:
            if let last = previous[w.id] {
                let dr = Double(sample.red - last.red), dg = Double(sample.green - last.green), db = Double(sample.blue - last.blue)
                let moved = (dr * dr + dg * dg + db * db).squareRoot() / ScreenPixelWatch.maxDistance
                if moved > w.tolerance {
                    pulseUntil[w.id] = now + Self.pulseSeconds
                    pulses[w.id, default: 0] &+= 1
                }
            }
        }
        previous[w.id] = sample
        sampledAt[w.id] = now
    }

    // MARK: - Reading the screen

    /// The display a watch reads: its own, nil while that one is not
    /// attached (reading the primary fired Change rows on an unplug), or
    /// with none set the primary (the one the flip math is relative to).
    static func screen(for watch: ScreenPixelWatch) -> NSScreen? {
        if let d = watch.display { return NSScreen.screens.first(where: { CursorRegionService.cachedKey(for: $0) == d }) }
        return NSScreen.screens.first
    }

    /// The 3 by 3 point square around the watch's point as whole pixels of
    /// its display (top-left origin), with the display and its scale; nil
    /// while the display is not attached or with the square off it. The
    /// square starts on a whole pixel and is 3 points a side, the pixel
    /// count a capture of its own had, read straight from the shared
    /// capture rather than resampled from a fractional source rect.
    static func pixelRect(for watch: ScreenPixelWatch) -> (rect: CGRect, display: CGDirectDisplayID, scale: CGFloat)? {
        guard let screen = screen(for: watch) else { return nil }
        let f = screen.frame, scale = screen.backingScaleFactor
        let local = CGPoint(x: watch.x * f.width, y: watch.y * f.height)
        let side = (3 * scale).rounded()
        let rect = CGRect(x: ((local.x - 1) * scale).rounded(), y: ((local.y - 1) * scale).rounded(), width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: (f.width * scale).rounded(), height: (f.height * scale).rounded()))
        guard !rect.isEmpty else { return nil }
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return (rect, CGDirectDisplayID(number), scale)
    }

    /// The average color of a 3 by 3 point square around the watch's point,
    /// cut the way a tick cuts it, from a capture of its own (the sheet's
    /// Pick). The completion runs on the main actor; nil when the screen
    /// could not be read (no permission, a display gone).
    static func sampleColor(for watch: ScreenPixelWatch, completion: @escaping @MainActor ((Int, Int, Int)?) -> Void) {
        guard let p = pixelRect(for: watch) else { completion(nil); return }
        sampleColors(of: [p.rect], within: p.rect, on: p.display, scale: p.scale) { completion($0?[0] ?? nil) }
    }

    /// One capture of `union` and the average color of each of `rects` cut
    /// from it, in order (all display pixels, top-left origin). The
    /// completion runs on the main actor: nil as a whole when the screen
    /// could not be read, nil for a rect with nothing in the capture.
    static func sampleColors(of rects: [CGRect], within union: CGRect, on display: CGDirectDisplayID, scale: CGFloat,
                             completion: @escaping @MainActor ([(Int, Int, Int)?]?) -> Void) {
        let source = CGRect(x: union.minX / scale, y: union.minY / scale, width: union.width / scale, height: union.height / scale)
        ScreenCapture.image(of: source, on: display, scale: scale) { image in
            let colors = image.map { image in rects.map { ScreenCapture.cut(image, at: $0, within: union).flatMap(averageColor) } }
            Task { @MainActor in completion(colors) }
        }
    }

    /// Draws the capture into a tiny RGBA buffer, whatever format it came
    /// in, and averages it.
    nonisolated static func averageColor(_ image: CGImage) -> (Int, Int, Int)? {
        let w = max(1, min(image.width, 16)), h = max(1, min(image.height, 16))
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // The context keeps the buffer's pointer, so it lives and draws
        // inside the closure that lends it; nothing escapes.
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var r = 0, g = 0, b = 0
        for i in stride(from: 0, to: buffer.count, by: 4) { r += Int(buffer[i]); g += Int(buffer[i + 1]); b += Int(buffer[i + 2]) }
        let n = w * h
        return (r / n, g / n, b / n)
    }

    /// The pointer's place in global top-left coordinates, and a watch
    /// for the display it is on, for Pick from the screen.
    static func watchUnderPointer() -> ScreenPixelWatch? {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) ?? NSScreen.main else { return nil }
        let f = screen.frame
        var w = ScreenPixelWatch()
        w.display = CursorRegionService.key(for: screen)
        w.x = min(1, max(0, (loc.x - f.origin.x) / f.width))
        w.y = min(1, max(0, 1 - (loc.y - f.origin.y) / f.height))
        return w
    }
}

/// One capture of a piece of a display, shared by the screen color and
/// screen text services, through ScreenCaptureKit (`captureImage(contentFilter:configuration:)`
/// is there from macOS 14.0, the deployment target) with the pointer left
/// out: a capture with the pointer in it read the arrow's own pixels under
/// it, and a watch under the pointer flipped while a preset ran.
/// ScreenCaptureKit needs its display list first; it is looked up once per
/// tracking run and again when the displays change or a capture fails.
@MainActor
enum ScreenCapture {
    private static var content: SCShareableContent? { didSet { contentGeneration &+= 1; nilCaptures = 0; filters = [:] } }
    /// One content filter per display from the list in hand: each capture
    /// built its own (81 us on main, 32 of them in one tick).
    private static var filters: [CGDirectDisplayID: SCContentFilter] = [:]
    private static var loading = false
    /// Which display list a capture was made from, so a slow capture from
    /// an older list cannot blank the one that just landed.
    private static var contentGeneration = 0
    /// Empty capture ticks in a row from the list in hand: one (a Space
    /// switch, Mission Control) no longer drops the list, which blinded
    /// every watch for the second the refetch waits. Captures that fail
    /// within the same moment count once, so three watches' one bad tick
    /// are one, not three.
    private static var nilCaptures = 0
    private static var lastNilAt: TimeInterval = -.infinity
    /// Lists dropped for failing captures in a row, and the wait they set:
    /// at the lock screen or with the display asleep every capture fails,
    /// and each list lasted three ticks, a fresh window walk three times a
    /// second for the length of the lock. The first drop refetches at once.
    private static var failedDrops = 0
    private static var refetchNotBefore: TimeInterval = 0
    private static var observing = false

    /// Called when tracking begins: forgets the display list and watches
    /// for the displays changing. Looks the list up only with the
    /// permission in hand, since the lookup itself would prompt.
    static func prepare() {
        // The list in hand stays until the fresh one lands: the two services
        // share it, and blanking it blinded the one already running.
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { content = nil; failedDrops = 0; refetchNotBefore = 0 }
            }
        }
        if ScreenRecordingPermission.hasAccess { refresh() }
    }

    /// A cluster's longest side, in pixels. Watches spread wider than this
    /// take separate captures, so two at opposite corners never make one
    /// capture the size of a Retina display (31 MB).
    nonisolated static let clusterCap: CGFloat = 1024

    /// Groups rects (display pixels) so each group's union stays within
    /// `clusterCap` a side: a group's first rect is in whatever its size,
    /// each later one joins the first group it fits. Each group's union
    /// and its members' indexes, in the order given.
    nonisolated static func clusters(of rects: [CGRect]) -> [(union: CGRect, members: [Int])] {
        var out: [(union: CGRect, members: [Int])] = []
        for (i, r) in rects.enumerated() {
            if let j = out.indices.first(where: {
                let u = out[$0].union.union(r)
                return u.width <= clusterCap && u.height <= clusterCap
            }) {
                out[j].union = out[j].union.union(r)
                out[j].members.append(i)
            } else {
                out.append((r, [i]))
            }
        }
        return out
    }

    /// The pixels of `rect` cut from a capture of `union` (both display
    /// pixels, top-left origin, as `CGImage.cropping(to:)` counts them),
    /// clipped to the image; nil with nothing of it there.
    nonisolated static func cut(_ image: CGImage, at rect: CGRect, within union: CGRect) -> CGImage? {
        let crop = rect.offsetBy(dx: -union.minX, dy: -union.minY)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return crop.isEmpty ? nil : image.cropping(to: crop)
    }

    /// When the display list was last asked for. Failing captures drop it
    /// on every tick, and asking again each time walked every window on
    /// the Mac several times a second.
    private static var refreshedAt: TimeInterval = -.infinity

    private static func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        // With no list in hand the gate waits for nothing: every watch read
        // nil for up to a second after a drop (nilCaptures limits a list
        // that keeps failing).
        guard !loading, now >= refetchNotBefore, content == nil || now - refreshedAt >= 1 else { return }
        refreshedAt = now
        loading = true
        Task { @MainActor in
            if let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) { content = fresh }
            loading = false
        }
    }

    /// `rect` is in the display's own top-left coordinates, in points, and
    /// is cut to the display (a watch at the very edge asks for a square
    /// partly off it); `scale` is the display's backing scale. The
    /// completion may run on any queue; nil when the screen could not be
    /// read (no permission, a display gone, the display list not there yet).
    static func image(of rect: CGRect, on display: CGDirectDisplayID, scale: CGFloat,
                      completion: @escaping @Sendable (CGImage?) -> Void) {
        guard let list = content else { refresh(); completion(nil); return }
        guard let d = list.displays.first(where: { $0.displayID == display }) else {
            content = nil; refresh(); completion(nil); return
        }
        let rect = rect.intersection(CGRect(origin: .zero, size: d.frame.size))
        guard !rect.isEmpty else { completion(nil); return }
        // InputConfig's own windows are left out, so a sheet or the editor
        // over the spot is read through, not as the color or text there.
        let filter: SCContentFilter
        if let kept = filters[display] {
            filter = kept
        } else {
            let own = list.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
            filters[display] = filter
        }
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = false
        config.capturesAudio = false
        let generation = contentGeneration
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
            Task { @MainActor in
                guard generation == contentGeneration else { return }
                if image == nil {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastNilAt > 0.05 { nilCaptures += 1; lastNilAt = now }
                    if nilCaptures >= 3 {
                        content = nil
                        failedDrops += 1
                        if failedDrops > 1 { refetchNotBefore = now + min(10, pow(2, Double(failedDrops - 2))) }
                    }
                } else {
                    nilCaptures = 0
                    failedDrops = 0
                    refetchNotBefore = 0
                }
            }
            completion(image)
        }
    }
}

/// The Screen Recording permission (Privacy & Security), which reading
/// pixels needs. macOS posts no notification when it changes, and a grant
/// counts only after the app is opened again; callers re-check when they
/// appear and after a request, and say so.
enum ScreenRecordingPermission {
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; after a refusal macOS shows
    /// nothing, so callers also offer Open System Settings. Returns true
    /// only when the permission is already there: a false means the
    /// prompt is up or the answer is not known yet, not a refusal.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
