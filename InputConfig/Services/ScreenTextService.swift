import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

/// Reads the words shown inside each of a preset's screen text watches
/// (`ScreenTextWatch`) with the Vision text recognizer, and says whether a
/// `.screenText` row is pressed. Same shape as `ScreenPixelService`: the
/// watches are the preset's, sampling is ref-counted and runs only while a
/// preset with such rows runs or the Screen Text sheet is open. Twice a
/// second: text recognition on a screen area costs more than a pixel, and
/// words on a screen do not change faster than that.
///
/// Needs the Screen Recording permission, like screen colors; the service
/// never prompts, and says once in the activity log when it is missing.
@MainActor
final class ScreenTextService: ObservableObject {
    static let shared = ScreenTextService()

    @Published private(set) var watches: [ScreenTextWatch] = []

    /// The last reading of each watch: the words seen and whether the
    /// watch's text was among them. Published only when either changes;
    /// when it was read is kept apart in `readAt`.
    struct Reading: Equatable {
        var text: String
        var found: Bool
    }
    @Published private(set) var readings: [UUID: Reading] = [:]
    private var readAt: [UUID: TimeInterval] = [:]

    /// What each watch's last capture gave, by a hash of its pixels, with
    /// the words and languages it was read for: a capture with the same
    /// pixels gives the same text without Vision. (Every capture was read
    /// again, 5 to 8 ms at the fast level and 30 to 60 at the accurate
    /// one, twice a second per watch, though a label mostly sits still.)
    struct LastRead: Sendable {
        var hash: UInt64
        var words: String
        var preferred: [String]
        var text: String
    }
    private var lastRead: [UUID: LastRead] = [:]

    static let rate: Double = 2

    private var timer: Timer?
    private var retainCount = 0
    private var inFlight: Set<UUID> = []
    private var pressed: Set<UUID> = []
    private var pulseUntil: [UUID: TimeInterval] = [:]
    /// Captures in a row that came back empty, per watch. Three let go of
    /// a held row: a lost display or permission otherwise kept its key
    /// down until the preset stopped.
    /// Bumped when tracking ends; see ScreenPixelService.run.
    private var run = 0
    /// Watches whose display was said to be missing, once each.
    private var saidMissing: Set<UUID> = []
    private var failedReads: [UUID: Int] = [:]

    private func noteFailedRead(_ id: UUID) {
        failedReads[id, default: 0] += 1
        guard failedReads[id, default: 0] >= 3 else { return }
        pressed.remove(id)
        pulseUntil[id] = nil
    }
    private var saidNoPermission = false
    /// The permission, asked of the system once a second rather than on
    /// every tick.
    private var hasPermission = false
    private var permissionCheckedAt: TimeInterval = 0
    /// Text recognition runs here, off the main actor and off the capture
    /// queue, so neither the window nor the pixel captures wait for it.
    nonisolated private static let recognitionQueue = DispatchQueue(label: "InputConfig.ScreenText.recognition", qos: .utility)

    /// Published, so the visualizer's list redraws when sampling starts
    /// or stops; follows `retainCount`.
    @Published private(set) var isTracking = false

    private init() {}

    // MARK: - The preset's watches

    func load(_ list: [ScreenTextWatch]) {
        let new = list.prefix(ScreenTextWatch.maxWatches).map { $0.clampedValues() }
        // A reload with the watch unchanged keeps what it read; Appears
        // skipped its first reading again on every edit otherwise.
        let same = Set(new.filter { watches.contains($0) }.map(\.id))
        watches = new
        readings = readings.filter { same.contains($0.key) }
        readAt = readAt.filter { same.contains($0.key) }
        lastRead = lastRead.filter { same.contains($0.key) }
        pulseUntil = pulseUntil.filter { same.contains($0.key) }
        pressed.formIntersection(same)
    }

    func allWatches() -> [ScreenTextWatch] { watches }

    func watch(with id: UUID) -> ScreenTextWatch? { watches.first { $0.id == id } }

    func upsert(_ watch: ScreenTextWatch) {
        let w = watch.clampedValues()
        if let i = watches.firstIndex(where: { $0.id == w.id }) {
            let was = watches[i]
            watches[i] = w
            // Another area or mode: what was read there says nothing about
            // now. New words: the reading is judged again, or words already
            // showing counted as having just appeared.
            if was.display != w.display || was.minX != w.minX || was.minY != w.minY || was.maxX != w.maxX
                || was.maxY != w.maxY || was.mode != w.mode {
                readings[w.id] = nil; readAt[w.id] = nil; pressed.remove(w.id); pulseUntil[w.id] = nil; lastRead[w.id] = nil
            } else if was.text != w.text, var reading = readings[w.id] {
                reading.found = Self.shows(w, in: reading.text)
                readings[w.id] = reading
                pulseUntil[w.id] = nil
            }
        } else if watches.count < ScreenTextWatch.maxWatches {
            watches.append(w)
        }
    }

    private static func shows(_ w: ScreenTextWatch, in text: String) -> Bool {
        let wanted = VoicePhraseService.words(of: w.text)
        return !wanted.isEmpty && VoicePhraseService.occurrences(of: wanted, in: VoicePhraseService.words(of: text)) > 0
    }

    func delete(_ id: UUID) {
        watches.removeAll { $0.id == id }
        readings[id] = nil; readAt[id] = nil; pressed.remove(id); pulseUntil[id] = nil; lastRead[id] = nil
    }

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
        pressed = []; pulseUntil = [:]; inFlight = []
        // A capture still in flight belongs to the run that ended.
        run &+= 1
        // The words read are not kept for the rest of the run.
        readings = [:]; readAt = [:]; lastRead = [:]
    }

    static let pulseSeconds: TimeInterval = 0.15

    func isPressed(_ id: UUID) -> Bool {
        guard timer != nil, let w = watch(with: id) else { return false }
        switch w.mode {
        case .shows: return pressed.contains(id)
        case .appears:
            guard let until = pulseUntil[id] else { return false }
            return ProcessInfo.processInfo.systemUptime < until
        }
    }

    private func tick() {
        guard !watches.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - permissionCheckedAt >= 1 {
            hasPermission = ScreenRecordingPermission.hasAccess
            permissionCheckedAt = now
        }
        guard hasPermission else {
            // Every row reads as not pressed, as the log line says.
            pressed.removeAll()
            pulseUntil.removeAll()
            if !saidNoPermission {
                saidNoPermission = true
                ActivityLog.shared.warning("Screen", "Screen text rows need Screen Recording allowed for InputConfig in System Settings, Privacy & Security; until then they read as not pressed. Quit and reopen InputConfig after allowing it")
            }
            return
        }
        let run = self.run
        for w in watches where !inFlight.contains(w.id) {
            inFlight.insert(w.id)
            let last = lastRead[w.id]
            Self.captureArea(for: w) { [weak self] image in
                guard let image else {
                    Task { @MainActor in
                        guard let self, self.run == run else { return }
                        self.inFlight.remove(w.id)
                        guard self.watch(with: w.id) == w else { return }
                        self.noteFailedRead(w.id)
                        // Off its display: back on it, Appears compares with
                        // nothing, as a pixel Change does. Said once per watch.
                        if Self.screen(for: w) == nil {
                            self.readings[w.id] = nil
                            if self.saidMissing.insert(w.id).inserted {
                                ActivityLog.shared.warning("Screen", "\(w.name) watches a display that is not connected; its rows read as not pressed until it is back")
                            }
                        }
                    }
                    return
                }
                // Recognition on its own queue; the result comes back here.
                Self.recognitionQueue.async {
                    // The same pixels read for the same words give the
                    // same text: Vision runs only on a changed capture.
                    let preferred = Locale.preferredLanguages
                    let hash = Self.pixelHash(image)
                    let text: String
                    if let hash, let last, last.hash == hash, last.words == w.text, last.preferred == preferred {
                        text = last.text
                    } else {
                        text = Self.recognizeText(in: image, lookingFor: w.text, preferred: preferred)
                    }
                    Task { @MainActor in
                        guard let self, self.run == run else { return }
                        self.inFlight.remove(w.id)
                        // A capture that finishes after its watch was
                        // deleted or changed would bring the old watch's
                        // state back.
                        guard self.watch(with: w.id) == w else { return }
                        self.saidMissing.remove(w.id)
                        self.failedReads[w.id] = nil
                        self.lastRead[w.id] = hash.map { LastRead(hash: $0, words: w.text, preferred: preferred, text: text) }
                        self.apply(text: text, to: w)
                    }
                }
            }
        }
    }

    private func apply(text: String, to w: ScreenTextWatch) {
        let now = ProcessInfo.processInfo.systemUptime
        // The watch's words as whole words, in a row, anywhere in the read
        // text: "ready" does not match "already", and a phrase inside a
        // longer line still counts.
        let found = Self.shows(w, in: text)
        let was = readings[w.id]?.found ?? false
        switch w.mode {
        case .shows:
            if found { pressed.insert(w.id) } else { pressed.remove(w.id) }
        case .appears:
            // Not on the first reading: text already on screen when the
            // preset started, reloaded or the editor closed has not just
            // appeared (the pixel service's Change waits for `previous`).
            if found && !was && readings[w.id] != nil { pulseUntil[w.id] = now + Self.pulseSeconds }
        }
        let reading = Reading(text: text, found: found)
        readAt[w.id] = now
        if readings[w.id] != reading { readings[w.id] = reading }
    }

    // MARK: - Reading the screen

    /// The display a watch reads: its own, nil while that one is not
    /// attached, or with none set the primary.
    static func screen(for watch: ScreenTextWatch) -> NSScreen? {
        if let d = watch.display { return NSScreen.screens.first(where: { CursorRegionService.cachedKey(for: $0) == d }) }
        return NSScreen.screens.first
    }

    /// The watch's area in global top-left coordinates and in its display's
    /// own, plus the display and its scale.
    static func rects(for watch: ScreenTextWatch) -> (global: CGRect, local: CGRect, display: CGDirectDisplayID, scale: CGFloat)? {
        guard let screen = screen(for: watch) else { return nil }
        let f = screen.frame
        let local = CGRect(x: watch.minX * f.width, y: watch.minY * f.height,
                           width: max(4, (watch.maxX - watch.minX) * f.width), height: max(4, (watch.maxY - watch.minY) * f.height))
        let mainHeight = NSScreen.screens.first?.frame.height ?? f.height
        let global = CGRect(x: f.origin.x + local.minX, y: mainHeight - (f.origin.y + f.height) + local.minY,
                            width: local.width, height: local.height)
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return (global, local, CGDirectDisplayID(number), screen.backingScaleFactor)
    }

    /// A capture of the watch's area. The completion may run on any queue.
    static func captureArea(for watch: ScreenTextWatch, completion: @escaping @Sendable (CGImage?) -> Void) {
        guard let r = rects(for: watch) else { completion(nil); return }
        ScreenCapture.image(of: r.local, on: r.display, scale: r.scale, completion: completion)
    }

    /// The words in the image in reading order (top to bottom, then left
    /// to right; Vision's boxes have their origin at the bottom left and
    /// come back in no set order), joined with spaces. No language
    /// correction, so a label is read as printed; the level and languages
    /// come from recognitionPlan.
    nonisolated static func recognizeText(in image: CGImage, lookingFor words: String,
                                          preferred: [String] = Locale.preferredLanguages) -> String {
        let plan = recognitionPlan(for: words, preferred: preferred)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = plan.accurate ? .accurate : .fast
        request.recognitionLanguages = plan.languages
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        // Lines first: sweeping down the boxes, one joins the open line
        // when its bottom sits within half the smaller box's height of the
        // line's first box, else it starts the next line. (Against the
        // first box, not the last added: a staircase of boxes each a
        // little lower than the one before could otherwise chain into one
        // line.) Each line then reads left to right. (A single comparator
        // mixing the two rules is not a strict weak ordering, and sorted()
        // gave shuffled lines.)
        var lines: [[VNRecognizedTextObservation]] = []
        for box in (request.results ?? []).sorted(by: { $0.boundingBox.minY > $1.boundingBox.minY }) {
            if let first = lines.last?.first,
               abs(first.boundingBox.minY - box.boundingBox.minY) <= min(first.boundingBox.height, box.boundingBox.height) / 2 {
                lines[lines.count - 1].append(box)
            } else {
                lines.append([box])
            }
        }
        let ordered = lines.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
        return ordered.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// A 64 bit hash of the image's pixels and shape, for telling a capture
    /// that has not changed; nil when its bytes cannot be read. Each row's
    /// padding is left out: it holds whatever the surface had there.
    /// (Swift's Hasher took 1.7 ms for 1.5 MB; this is a multiply and a
    /// shift per 8 bytes.)
    nonisolated static func pixelHash(_ image: CGImage) -> UInt64? {
        guard image.height > 0, let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let rowBytes = image.bytesPerRow, used = (image.width * image.bitsPerPixel + 7) / 8
        guard used <= rowBytes, rowBytes * (image.height - 1) + used <= CFDataGetLength(data) else { return nil }
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for v in [UInt64(image.width), UInt64(image.height), UInt64(image.bitsPerPixel), UInt64(image.bitmapInfo.rawValue)] {
            h = (h ^ v) &* 0x9E37_79B9_7F4A_7C15; h ^= h >> 29
        }
        let raw = UnsafeRawPointer(base)
        for row in 0..<image.height {
            let line = raw + row * rowBytes
            var i = 0
            while i + 8 <= used {
                h = (h ^ line.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0x9E37_79B9_7F4A_7C15; h ^= h >> 29
                i += 8
            }
            var tail: UInt64 = 0
            while i < used { tail = tail << 8 | UInt64(line.load(fromByteOffset: i, as: UInt8.self)); i += 1 }
            h = (h ^ tail) &* 0x9E37_79B9_7F4A_7C15; h ^= h >> 29
        }
        return h
    }

    /// What each recognition level reads, asked of Vision once.
    private nonisolated static let readableLanguages: (fast: [String], accurate: [String]) = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        let fast = (try? request.supportedRecognitionLanguages()) ?? []
        request.recognitionLevel = .accurate
        return (fast, (try? request.supportedRecognitionLanguages()) ?? [])
    }()

    /// The languages a watch is read in: the Mac's own, the script of the
    /// words it looks for, then English. Vision reads only English unless
    /// told, and the fast level reads a few Latin script languages, so the
    /// slower accurate level is used only when the words' own script needs
    /// it: the Mac's language alone would send most Macs there.
    nonisolated static func recognitionPlan(for words: String, preferred: [String]) -> (languages: [String], accurate: Bool) {
        func pick(_ code: String, in list: [String]) -> String? {
            list.first { $0.caseInsensitiveCompare(code) == .orderedSame }
                ?? list.first { code.hasPrefix($0 + "-") }
                ?? list.first { $0.split(separator: "-").first == code.split(separator: "-").first }
        }
        func unique(_ list: [String]) -> [String] {
            var seen: Set<String> = []
            return list.filter { seen.insert($0).inserted }
        }
        let script = scriptLanguages(of: words)
        let wanted = preferred + script + ["en-US"]
        let readable = readableLanguages
        if script.allSatisfy({ pick($0, in: readable.fast) != nil }) {
            let fast = unique(wanted.compactMap { pick($0, in: readable.fast) })
            return (fast.isEmpty ? ["en-US"] : fast, false)
        }
        let accurate = unique(wanted.compactMap { pick($0, in: readable.accurate) })
        return (accurate.isEmpty ? ["en-US"] : accurate, true)
    }

    /// The languages the words' own script points to, for words typed in
    /// another script than the Mac's language.
    private nonisolated static func scriptLanguages(of words: String) -> [String] {
        var out: [String] = []
        for scalar in words.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: out.append("ja-JP")
            case 0xAC00...0xD7A3, 0x1100...0x11FF: out.append("ko-KR")
            case 0x4E00...0x9FFF: out.append("zh-Hans")
            case 0x0400...0x04FF: out.append("ru-RU")
            case 0x0600...0x06FF: out.append("ar-SA")
            case 0x0E00...0x0E7F: out.append("th-TH")
            default: break
            }
        }
        return out
    }

    /// The pointer's place as a share of the display it is on, for marking
    /// the area's corners.
    static func pointerPlace() -> (display: DisplayKey, x: Double, y: Double)? {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) ?? NSScreen.main else { return nil }
        let f = screen.frame
        return (CursorRegionService.key(for: screen),
                min(1, max(0, (loc.x - f.origin.x) / f.width)),
                min(1, max(0, 1 - (loc.y - f.origin.y) / f.height)))
    }
}
