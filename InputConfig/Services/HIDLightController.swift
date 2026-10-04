import Foundation
import GameController
import IOKit
import IOKit.hid

// The light bar is written in-process by InProcessLightWriter, below. The
// LightHelper subprocess and the HIDLightController that launched it were
// removed in 1.6: nothing used them once the in-process writer took over.

/// Ties one physical Sony pad seen through GameController to the same pad
/// seen through raw IOKit HID, so per-slot work (the light bar, rumble, the
/// Edge's paddles) reaches the right controller when two are connected.
///
/// A raw HID device is described by its own IOHIDDevice registry node plus
/// the properties IOKit publishes on it. A GameController pad is described
/// by the registry nodes behind its HID services (the service and its
/// parents, one of which is the IOHIDDevice) and its physical device ID.
/// Either side matching the other on any of these counts as the same pad.
struct SonyPadIdentity: Equatable, Sendable {
    /// Registry entry ID of the IOHIDDevice node (raw side), or 0.
    var nodeID: UInt64 = 0
    /// Registry entry IDs of a GameController pad's HID services and their
    /// parents (GameController side). Always includes `nodeID` when set.
    var lineage: Set<UInt64> = []
    var locationID: UInt64?
    var serial: String?
    var uniqueID: String?

    var isEmpty: Bool {
        nodeID == 0 && lineage.isEmpty && locationID == nil
            && (serial ?? "").isEmpty && (uniqueID ?? "").isEmpty
    }

    /// True when both describe the same physical pad. Location IDs are
    /// compared last because a Bluetooth reconnect can reuse one.
    func matches(_ other: SonyPadIdentity) -> Bool {
        if nodeID != 0, other.lineage.contains(nodeID) { return true }
        if other.nodeID != 0, lineage.contains(other.nodeID) { return true }
        if let u = uniqueID, !u.isEmpty, u == other.uniqueID { return true }
        if let s = serial, !s.isEmpty, s == other.serial { return true }
        if let l = locationID, l != 0, l == other.locationID { return true }
        return false
    }

    // MARK: Raw HID side

    /// Identity of a raw IOHIDDevice. Cheap enough to call at attach time.
    static func of(device: IOHIDDevice) -> SonyPadIdentity {
        var id = SonyPadIdentity()
        let service = IOHIDDeviceGetService(device)
        if service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                id.nodeID = entryID
                id.lineage = [entryID]
            }
        }
        id.locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value
        id.serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        id.uniqueID = IOHIDDeviceGetProperty(device, kIOHIDPhysicalDeviceUniqueIDKey as CFString) as? String
        return id
    }

    /// Identity of a raw registry entry (the enumeration path, which never
    /// makes an IOHIDDevice for pads it skips).
    static func of(entry: io_registry_entry_t) -> SonyPadIdentity {
        var id = SonyPadIdentity()
        var entryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS {
            id.nodeID = entryID
            id.lineage = [entryID]
        }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        id.locationID = (prop(kIOHIDLocationIDKey) as? NSNumber)?.uint64Value
        id.serial = prop(kIOHIDSerialNumberKey) as? String
        id.uniqueID = prop(kIOHIDPhysicalDeviceUniqueIDKey) as? String
        return id
    }

    // MARK: GameController side

    private final class CacheEntry {
        weak var controller: GCController?
        let identity: SonyPadIdentity
        let builtAt: CFAbsoluteTime
        init(controller: GCController, identity: SonyPadIdentity, builtAt: CFAbsoluteTime) {
            self.controller = controller
            self.identity = identity
            self.builtAt = builtAt
        }
    }
    nonisolated(unsafe) private static var cache: [ObjectIdentifier: CacheEntry] = [:]
    private static let cacheLock = NSLock()

    /// Identity of a GameController pad, or nil when GameController does not
    /// say which HID device backs it. Cached per controller object, since
    /// the state read asks for it every poll frame; an empty answer is
    /// retried every two seconds in case the HID services arrive late. So is
    /// a partial one (an id but no HID services yet), which used to be kept
    /// for good and left per-pad matching on the id string alone.
    static func of(controller: GCController) -> SonyPadIdentity? {
        let key = ObjectIdentifier(controller)
        let now = CFAbsoluteTimeGetCurrent()
        cacheLock.lock()
        if let hit = cache[key], hit.controller === controller,
           !hit.identity.lineage.isEmpty || now - hit.builtAt < 2 {
            cacheLock.unlock()
            return hit.identity.isEmpty ? nil : hit.identity
        }
        cacheLock.unlock()

        let built = build(for: controller)
        cacheLock.lock()
        cache = cache.filter { $0.value.controller != nil }
        cache[key] = CacheEntry(controller: controller, identity: built, builtAt: now)
        cacheLock.unlock()
        return built.isEmpty ? nil : built
    }

    /// GameController keeps the HID services behind each pad in an
    /// unpublished `hidServices` list (each item carries a `registryID`) and
    /// the pad's `physicalDeviceUniqueID`. Both are read defensively: every
    /// selector is checked first, so a macOS release that renames them just
    /// yields no identity, and callers fall back to their single-pad path.
    private static func build(for controller: GCController) -> SonyPadIdentity {
        var id = SonyPadIdentity()
        if controller.responds(to: NSSelectorFromString("physicalDeviceUniqueID")),
           let u = controller.value(forKey: "physicalDeviceUniqueID") as? String, !u.isEmpty {
            id.uniqueID = u
        }
        guard controller.responds(to: NSSelectorFromString("hidServices")),
              let services = controller.value(forKey: "hidServices") as? [NSObject] else { return id }
        for info in services {
            guard info.responds(to: NSSelectorFromString("registryID")),
                  let reg = (info.value(forKey: "registryID") as? NSNumber)?.uint64Value,
                  reg != 0 else { continue }
            addLineage(ofRegistryID: reg, to: &id)
        }
        return id
    }

    /// Walk up from one HID service to its IOHIDDevice (a few levels at
    /// most), recording every node, and pick up the device properties from
    /// the nearest node that publishes them.
    private static func addLineage(ofRegistryID reg: UInt64, to id: inout SonyPadIdentity) {
        guard let matching = IORegistryEntryIDMatching(reg) else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        let search = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func find(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                            kCFAllocatorDefault, search)
        }
        if id.locationID == nil { id.locationID = (find(kIOHIDLocationIDKey) as? NSNumber)?.uint64Value }
        if (id.serial ?? "").isEmpty { id.serial = find(kIOHIDSerialNumberKey) as? String }
        if (id.uniqueID ?? "").isEmpty { id.uniqueID = find(kIOHIDPhysicalDeviceUniqueIDKey) as? String }

        var current: io_registry_entry_t = service
        IOObjectRetain(current)
        for _ in 0..<6 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(current, &entryID) == KERN_SUCCESS {
                id.lineage.insert(entryID)
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            current = 0
            guard kr == KERN_SUCCESS, parent != 0 else { break }
            current = parent
        }
        if current != 0 { IOObjectRelease(current) }
    }
}

/// Writes DualSense / DualShock 4 light-bar colors directly from the app
/// process, in shared (non-seize) mode, with no helper process and no
/// gamecontrolleragentd kill.
///
/// Devices are opened once (shared, coexisting with the system daemon) and
/// the handles reused for fast repeated writes. All IOKit access is
/// serialized on a private queue, so call `open`/`write`/`close` from any
/// thread. `write` lazily opens if needed, so a bare `write` also works.
final class InProcessLightWriter: @unchecked Sendable {
    nonisolated(unsafe) static let shared = InProcessLightWriter()

    private let queue = DispatchQueue(label: "com.inputconfig.inproclight")
    /// Every opened Sony pad. `key` is the pad's IOHIDDevice registry entry
    /// ID (stable while it stays connected, so it survives a rescan), and
    /// `identity` is what a GameController slot is matched against.
    private var devices: [(dev: IOHIDDevice, pid: Int32, isBT: Bool, key: UInt64, identity: SonyPadIdentity)] = [] {
        didSet {
            let has = !devices.isEmpty
            flagLock.lock(); hasDevices = has; flagLock.unlock()
        }
    }
    /// Whether any pad is open, readable without waiting on `queue`: a
    /// haptic row asked through queue.sync from the engine's main-thread
    /// poll and waited behind a slow Bluetooth write to a fading pad.
    private let flagLock = NSLock()
    private var hasDevices = false
    private var sequenceTag: UInt8 = 0
    /// DualSense pads (by registry entry ID) already sent the light bar
    /// setup. Its one value this app uses (0x02) fades out the blue light
    /// the pad turns on at connect, which hands the bar to the app's color;
    /// SDL and the kernel send it once per connection, not on every color
    /// write. Touched only on `queue`.
    private var lightSetupSent = Set<UInt64>()
    /// Current solid color to re-assert and the high-rate timer that does it.
    /// Both are touched only on `queue`. `holdColor` applies to every pad
    /// that has no color of its own in `deviceHold`; a write aimed at one
    /// slot's pad lands in `deviceHold`, so two pads can hold two colors.
    private var holdColor: (r: UInt8, g: UInt8, b: UInt8)?
    private var deviceHold: [UInt64: (r: UInt8, g: UInt8, b: UInt8)] = [:]
    /// Rumble rides in the same output report as the light bar. Two writers
    /// with separate Bluetooth sequence counters make the controller drop
    /// packets, which is why the app's 60 Hz light hold silenced the rumble
    /// gamecontrollerd was sending: the buzz only played once the app quit
    /// and the contention stopped. One writer, one sequence, no contention.
    /// Kept per pad (by device key) so a buzz meant for one slot does not
    /// shake every Sony pad on the Mac.
    private var rumbles: [UInt64: (strong: UInt8, weak: UInt8, until: CFAbsoluteTime)] = [:]
    #if DEBUG
    /// Which vibration flags the report claims, for measuring on a pad:
    /// 0 the shipped default (the older compatible-vibration flag with
    /// haptics select, and nothing else), 1 the same, 2 the newer
    /// improved-rumble flag instead. Measured on a DualSense Edge, Sep 18
    /// 2026, ten variants back to back with a preset running: the newer
    /// flag flattened the motors so 100% felt like 20%; the older flag
    /// alone was much stronger and scaled. It is not set any more.
    nonisolated(unsafe) static var debugVibrationMode = 0
    /// Which motors carry the level: 0 both, 1 the strong (left) motor
    /// only, 2 the weak (right) motor only.
    nonisolated(unsafe) static var debugMotorMask = 0
    #endif
    /// Whether the report also claims the pad's newer "improved rumble"
    /// mode (valid_flag2 bit 0x04) alongside the classic one. Per model,
    /// from what each pad measured: the plain DualSense (0x0CE6) keeps
    /// both, the report that has worked on it all along; the DualSense
    /// Edge (0x0DF2) gets the classic flag alone, because on the Edge the
    /// newer mode flattened the motors so 100% felt like 20% (Sep 18 2026,
    /// ten-variant rig). The debug mode forces it either way.
    ///
    /// A deliberate difference from the references: the kernel and SDL read
    /// the pad's firmware version (feature report 0x20) and claim one
    /// compatibility flag, the newer one from firmware 2.21 (0x0224) on.
    /// These flags were measured on real pads instead, the plain DualSense
    /// with both and the Edge with the classic one alone, and kept as
    /// measured rather than switched to a choice that could not be tested.
    private func improvedRumble(pid: Int32) -> Bool {
        if vibrationMode == 1 { return false }
        if vibrationMode == 2 { return true }
        return pid != 0x0DF2
    }

    private var motorMask: Int {
        #if DEBUG
        return Self.debugMotorMask
        #else
        return 0
        #endif
    }
    private var vibrationMode: Int {
        #if DEBUG
        return Self.debugVibrationMode
        #else
        return 0
        #endif
    }
    /// One last all-zero write is needed to stop the motors, per pad.
    private var rumbleNeedsStop: Set<UInt64> = []

    /// Which pads a write aimed at `target` should reach, or nil for every
    /// pad. With one pad (or no target, or a target no pad matches) this is
    /// nil, so single-pad behavior and the fallback when GameController does
    /// not say which HID device backs a slot both stay the old "write them
    /// all" path.
    private func resolveLocked(_ target: SonyPadIdentity?) -> Set<UInt64>? {
        guard let target, devices.count > 1 else { return nil }
        let hits = Set(devices.filter { $0.identity.matches(target) }.map(\.key))
        return hits.isEmpty ? nil : hits
    }

    private var hasAnyHoldLocked: Bool { holdColor != nil || !deviceHold.isEmpty }

    /// True when this controller's report stream belongs to us, so
    /// FeedbackService knows to route the buzz here instead of CHHaptics.
    var ownsAnyDualSense: Bool {
        flagLock.lock(); defer { flagLock.unlock() }
        return hasDevices
    }

    #if DEBUG
    /// Let go of the controller completely, so another process has the
    /// output report stream to itself. For the buzz test only.
    func closeForTest() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.holdTimer?.cancel(); self.holdTimer = nil
            self.holdColor = nil
            self.deviceHold.removeAll()
            self.closeLocked()   // stops the motors before letting go
        }
    }
    #endif

    /// Stop writing for a moment. Two processes writing output reports to
    /// one DualSense fight; this hands the stream to whoever else wants it.
    private var quietUntil: CFAbsoluteTime = 0
    func pauseWrites(forMs ms: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.quietUntil = CFAbsoluteTimeGetCurrent() + Double(ms) / 1000
            // macOS repaints the light bar itself while it is driving the
            // haptics, so the held color has to be taken straight back the
            // moment the pause ends. Waiting for the next heartbeat would
            // leave the system's color showing for up to a second, which
            // reads as the light changing every time a row buzzes.
            self.queue.asyncAfter(deadline: .now() + .milliseconds(ms + 20)) { [weak self] in
                guard let self = self, self.hasAnyHoldLocked else { return }
                self.burstLocked()
            }
        }
    }

    /// Vibrate a Sony pad through the report we already own.
    /// `intensity` 0...1, `durationMs` clamped to something short.
    /// What the last vibrate call asked for, for the debug dump.
    nonisolated(unsafe) static var debugLastVibrate: String = "none"

    /// `target` picks the pad (see `SonyPadIdentity`); nil buzzes every pad.
    func vibrate(intensity: Float, durationMs: Int, target: SonyPadIdentity? = nil) {
        let level = UInt8(max(0, min(1, intensity)) * 255)
        let seconds = Double(max(40, min(2000, durationMs))) / 1000
        Self.debugLastVibrate = "intensity=\(intensity) level=\(level) ms=\(durationMs) at=\(Date())"
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.devices.isEmpty { self.reopenLocked() }
            guard !self.devices.isEmpty else { return }
            let only = self.resolveLocked(target)
            let until = CFAbsoluteTimeGetCurrent() + seconds
            for d in self.devices where only == nil || only!.contains(d.key) {
                self.rumbles[d.key] = (strong: level, weak: level, until: until)
                self.rumbleNeedsStop.insert(d.key)
            }
            self.writeLocked(only: only)
            self.ensureTickerLocked()
            // Stop on time. The heartbeat writes once a second, so a 100 ms
            // buzz otherwise ran until the next heartbeat, up to a second.
            self.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                if self.rumbles.values.contains(where: { CFAbsoluteTimeGetCurrent() >= $0.until }) {
                    self.writeLocked(only: only)
                }
            }
        }
    }

    /// A slow heartbeat, not a 60 Hz re-assert. Writing every frame meant
    /// this app and the system's own controller daemon were both pushing
    /// output reports at the pad: the light visibly flickered and the
    /// daemon's rumble packets were lost among ours, so a buzz was only
    /// felt once this app stopped writing. One write per second keeps the
    /// color without owning the stream.
    /// Ten writes over the next 200 ms, so a color change takes hold at once.
    private func burstLocked() {
        for i in 1...10 {
            queue.asyncAfter(deadline: .now() + .milliseconds(i * 20)) { [weak self] in
                guard let self = self, self.hasAnyHoldLocked else { return }
                self.writeLocked()
            }
        }
    }

    private func ensureTickerLocked() {
        guard holdTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(1000), repeating: .milliseconds(1000), leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let hasColor = self.hasAnyHoldLocked
            let hasRumble = !self.rumbles.isEmpty || !self.rumbleNeedsStop.isEmpty
            guard hasColor || hasRumble else {
                self.holdTimer?.cancel(); self.holdTimer = nil; return
            }
            self.writeLocked()
        }
        holdTimer = t
        t.resume()
    }
    private var holdTimer: DispatchSourceTimer?

    /// Reusable output-report buffers, one per controller report layout.
    /// The hold timer calls writeLocked at 200 Hz; allocating a fresh
    /// [UInt8] on every tick was 200 array allocations per second per
    /// connected controller. These are mutated and sent only on `queue`
    /// (writeLocked is serial), so reuse is race-free. Every write rewrites
    /// the same byte positions, and the zero padding between fields is never
    /// touched, so a reused buffer stays byte-identical to a fresh one.
    private var bufDualSenseUSB = [UInt8](repeating: 0, count: 48)
    private var bufDualSenseBT = [UInt8](repeating: 0, count: 78)
    private var bufDS4USB = [UInt8](repeating: 0, count: 32)
    private var bufDS4BT = [UInt8](repeating: 0, count: 78)

    private static let sonyVID: Int32 = 0x054C
    private static let dualSensePIDs: Set<Int32> = [0x0CE6, 0x0DF2]
    /// DS4 v1, DS4 v2, and Sony's DS4 USB wireless adapter (0x0BA0), which
    /// presents the paired pad with the wired DS4 report layout. The
    /// PlayStation Access controller (0x0E5F) is left out: its output report
    /// has not been verified against the DualSense layout, and it has no
    /// rumble motors.
    private static let ds4PIDs: Set<Int32> = [0x05C4, 0x09CC, 0x0BA0]

    private init() {}

    /// Enumerate and open every connected DualSense / DS4 in shared mode.
    /// Safe to call repeatedly; re-opens from scratch each time so it also
    /// serves as a "rescan after hotplug" call.
    func open()  { queue.async { [weak self] in self?.reopenLocked() } }

    /// Close every opened controller. Call when the cycle stops so we don't
    /// hold the devices open indefinitely.
    func close() { queue.async { [weak self] in self?.closeLocked() } }

    /// Write an LED color to the target pad, or to every opened controller
    /// when `target` is nil or matches none. RGB + brightness byte match the
    /// DualSense and DualShock 4 output report layout. Cheap enough to call at 60 Hz.
    func write(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8 = 2,
               target: SonyPadIdentity? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.devices.isEmpty { self.reopenLocked() }
            let only = self.resolveLocked(target)
            // If a hold loop is re-asserting a color at 200 Hz, a bare write
            // would be repainted within milliseconds. Update the held color so
            // this write sticks; callers restore the previous color afterward.
            if self.holdTimer != nil { self.setHoldLocked((red, green, blue), only: only) }
            self.writeLocked(bare: (red, green, blue, brightness), only: only)
        }
    }

    /// Record a held color for the given pads, or for every pad when `only`
    /// is nil (which also drops any per-pad colors, the old single-color
    /// behavior).
    private func setHoldLocked(_ c: (r: UInt8, g: UInt8, b: UInt8), only: Set<UInt64>?) {
        if let only {
            for key in only { deviceHold[key] = c }
        } else {
            holdColor = c
            deviceHold.removeAll()
        }
    }

    /// Continuously re-assert a solid color at a high rate so macOS 26's
    /// controller daemon, which repaints the LED on focus changes and on a loop
    /// while we're foreground, is overwritten within a few milliseconds, before
    /// it's visible. Runs on this writer's own queue, so it keeps firing at full
    /// rate even when the app is backgrounded and the main run loop is throttled.
    /// Call again to change the held color; call `stopHold()` to end it.
    /// `target` holds the color on one slot's pad only; nil holds it on all.
    func startHold(red: UInt8, green: UInt8, blue: UInt8, target: SonyPadIdentity? = nil) {
        queue.async { [weak self] in
            guard let self = self, self.ensureDevicesLocked() else { return }
            let only = self.resolveLocked(target)
            self.setHoldLocked((red, green, blue), only: only)
            self.writeLocked(only: only)  // immediate
            // A short burst wins the color, then the slow heartbeat holds it.
            // The system's controller daemon repaints the LED around a focus
            // change, so the first fraction of a second is the only moment
            // that needs repeated writes; keeping that rate up afterwards is
            // what made the light flicker and swallowed the rumble.
            self.burstLocked()
            self.ensureTickerLocked()
        }
    }

    /// One frame of an animation (the rainbow cycle): the held color moves
    /// on and is written once. startHold's ten-write burst on every 40 Hz
    /// frame sent about 440 reports a second to each pad, the flicker and
    /// lost-rumble pattern the heartbeat exists to avoid.
    func setHeldColor(red: UInt8, green: UInt8, blue: UInt8, target: SonyPadIdentity? = nil) {
        queue.async { [weak self] in
            guard let self = self, self.ensureDevicesLocked() else { return }
            let only = self.resolveLocked(target)
            self.setHoldLocked((red, green, blue), only: only)
            self.writeLocked(only: only)
            self.ensureTickerLocked()
        }
    }

    /// Open the Sony pads if none are open yet, and say whether there is one.
    /// The registry scan runs at most every five seconds while there is
    /// nothing to find: with no Sony pad connected, every light change
    /// re-enumerated the registry. The full-rate activity (no App Nap) is
    /// taken only while a pad is actually being held.
    private var lastEmptyScan: CFAbsoluteTime = 0
    private func ensureDevicesLocked() -> Bool {
        if devices.isEmpty {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastEmptyScan > 5 else { return false }
            reopenLocked()
            if devices.isEmpty { lastEmptyScan = now; return false }
        }
        // Full rate (no App Nap) only for a few seconds after a change, or
        // while changes keep coming (a cycle, a rumble); the 1 Hz heartbeat
        // on its own runs fine napping. Held for the whole session, a
        // connected PlayStation pad kept the app from ever napping.
        if !holdsActivity {
            holdsActivity = true
            Task { @MainActor in AppActivity.shared.retain("light") }
        }
        activityGeneration &+= 1
        let gen = activityGeneration
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.activityGeneration == gen, self.holdsActivity else { return }
            self.holdsActivity = false
            Task { @MainActor in AppActivity.shared.release("light") }
        }
        return true
    }
    private var holdsActivity = false
    private var activityGeneration = 0

    func stopHold() {
        queue.async { [weak self] in
            guard let self, self.holdsActivity else { return }
            self.holdsActivity = false
            Task { @MainActor in AppActivity.shared.release("light") }
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.holdColor = nil
            self.deviceHold.removeAll()
            // The ticker stops itself once nothing is held and no rumble is
            // playing, so a buzz mid-release still finishes.
            if self.rumbles.isEmpty && self.rumbleNeedsStop.isEmpty {
                self.holdTimer?.cancel()
                self.holdTimer = nil
            }
        }
    }

    // MARK: - queue-only internals

    private func reopenLocked() {
        closeLocked()
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDVendorIDKey as String] = Self.sonyVID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard let pidRef = IORegistryEntryCreateCFProperty(entry, kIOHIDProductIDKey as CFString, kCFAllocatorDefault, 0) else { continue }
            // Read the ProductID defensively. IORegistry properties are
            // device-reported, so a forced cast would crash the app if any
            // Sony-VID device ever reported this as something other than a
            // number. This mirrors the safe as? handling used for the
            // transport key just below.
            guard let pid = (pidRef.takeRetainedValue() as? NSNumber)?.int32Value else { continue }
            guard Self.dualSensePIDs.contains(pid) || Self.ds4PIDs.contains(pid) else { continue }
            guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, entry) else { continue }
            let identity = SonyPadIdentity.of(entry: entry)
            // Shared (non-exclusive) open: coexists with gamecontrolleragentd.
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            var isBT = false
            if let tRef = IORegistryEntryCreateCFProperty(entry, kIOHIDTransportKey as CFString, kCFAllocatorDefault, 0) {
                isBT = ((tRef.takeRetainedValue() as? String) ?? "").lowercased().contains("bluetooth")
            }
            // Registry IDs are unique per node; the fallback only matters if
            // the lookup ever fails, and keeps keys distinct regardless.
            let key = identity.nodeID != 0 ? identity.nodeID : UInt64(devices.count + 1)
            devices.append((dev, pid, isBT, key, identity))
        }
        // Forget per-pad state for pads that are gone.
        let live = Set(devices.map(\.key))
        deviceHold = deviceHold.filter { live.contains($0.key) }
        rumbles = rumbles.filter { live.contains($0.key) }
        rumbleNeedsStop.formIntersection(live)
        // A pad can arrive already buzzing, left that way by a crash or by a
        // previous run that let go mid-pulse. Silence it on the way in.
        if !devices.isEmpty { stopMotorsLocked() }
    }

    /// Force the motors to zero right now. A DualSense holds the last motor
    /// level it was given until something tells it otherwise, so letting go
    /// of the device with a buzz in flight leaves it rumbling forever with
    /// nobody left to stop it. This ignores the quiet window and the timer
    /// on purpose: a stop must never be the write that gets skipped.
    private func stopMotorsLocked() {
        guard !devices.isEmpty else { return }
        let saved = quietUntil
        quietUntil = 0
        rumbles.removeAll()
        rumbleNeedsStop = Set(devices.map(\.key))
        writeLocked(touchLight: false)
        rumbleNeedsStop.removeAll()
        quietUntil = saved
    }

    /// Quit path: stop the motors and let go of the pads before the process
    /// exits. Synchronous, because an async hop does not survive termination
    /// and the pad would be left buzzing with nothing able to stop it.
    func shutdownSynchronously() {
        queue.sync {
            holdTimer?.cancel(); holdTimer = nil
            holdColor = nil
            deviceHold.removeAll()
            if devices.isEmpty { reopenLocked() }
            closeLocked()
        }
    }

    #if DEBUG
    /// What this writer is holding right now, for the debug readout.
    var debugState: String {
        let mode: String
        #if DEBUG
        mode = " mode=\(Self.debugVibrationMode)"
        #else
        mode = ""
        #endif
        _ = mode
        var out = ""
        queue.sync {
            let c = holdColor.map { "(\($0.r),\($0.g),\($0.b))" } ?? "none"
            let quiet = max(0, quietUntil - CFAbsoluteTimeGetCurrent())
            out = "devices=\(devices.count) holdColor=\(c) perPad=\(deviceHold.count) ticker=\(holdTimer != nil) "
                + "quietFor=\(String(format: "%.2f", quiet))s rumble=\(!rumbles.isEmpty)"
        }
        out += "\nlastVibrate: \(Self.debugLastVibrate)\nlastPath: \(FeedbackService.debugLastPath)"
        return out
    }
    #endif

    /// Stop any buzz this app, or a previous run of it, left running.
    func stopMotors() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.devices.isEmpty { self.reopenLocked() } else { self.stopMotorsLocked() }
        }
    }

    private func closeLocked() {
        stopMotorsLocked()
        for d in devices { IOHIDDeviceClose(d.dev, 0) }
        devices.removeAll()
    }

    /// `touchLight` false sends the motor fields without claiming the light
    /// bar. Every output report says which fields it owns, and a report that
    /// claims the light bar sets it, so a write that only meant to stop the
    /// motors would also blank the LED.
    ///
    /// Each pad gets its own color (`bare` when this is a one-off write aimed
    /// at it, else its held color) and its own motor levels. `only` limits
    /// the write to some pads; nil writes every pad.
    private func writeLocked(bare: (r: UInt8, g: UInt8, b: UInt8, br: UInt8)? = nil,
                             only: Set<UInt64>? = nil,
                             touchLight: Bool = true) {
        let now = CFAbsoluteTimeGetCurrent()
        if now < quietUntil { return }
        for d in devices where only == nil || only!.contains(d.key) {
            // Motor levels for this write, and whether the report should
            // claim the vibration fields at all.
            var strong: UInt8 = 0, weak: UInt8 = 0
            var touchMotors = false
            if let r = rumbles[d.key] {
                if now < r.until {
                    strong = r.strong; weak = r.weak; touchMotors = true
                } else {
                    rumbles[d.key] = nil     // expired: one zero write stops it
                    touchMotors = true
                }
            } else if rumbleNeedsStop.contains(d.key) {
                touchMotors = true
                rumbleNeedsStop.remove(d.key)
            }
            // This pad's color. With nothing held anywhere the report carries
            // an unlit color, as it always has; a pad with no color of its own
            // while another pad holds one is left alone instead of blanked.
            var touchLight = touchLight
            var red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0, brightness: UInt8 = 0
            if let b = bare {
                red = b.r; green = b.g; blue = b.b; brightness = b.br
            } else if let c = deviceHold[d.key] ?? holdColor {
                red = c.r; green = c.g; blue = c.b; brightness = 2
            } else if !deviceHold.isEmpty {
                touchLight = false
            }
            // Nothing to say to this pad on this write.
            if !touchLight && !touchMotors { continue }
            let isDS = Self.dualSensePIDs.contains(d.pid)
            let setup = isDS && touchLight && !lightSetupSent.contains(d.key)
            if setup { lightSetupSent.insert(d.key) }
            if isDS && !d.isBT {
                bufDualSenseUSB[0] = 0x02
                bufDualSenseUSB[2] = touchLight ? 0x04 : 0x00   // valid_flag1: light bar
                // valid_flag2: light setup, plus the newer vibration path only
                // when this report is actually carrying motor values. Claiming
                // vibration on every light write cancels the buzz the system
                // is in the middle of playing.
                bufDualSenseUSB[39] = (setup ? 0x02 : 0x00) | (touchMotors && improvedRumble(pid: d.pid) ? 0x04 : 0x00)
                bufDualSenseUSB[42] = setup ? 0x02 : 0x00
                // valid_flag0: bit 0 claims the two motor bytes that follow,
                // and bit 1 is haptics select, which switches the pad out of
                // audio haptics and back onto the classic motors. Without
                // that second bit the motor values are accepted and ignored:
                // measured on a DualSense, the same report buzzes with it and
                // does nothing without it.
                bufDualSenseUSB[1] = touchMotors ? (vibrationMode == 2 ? 0x02 : 0x03) : 0x00
                bufDualSenseUSB[3] = touchMotors && motorMask != 1 ? weak : 0
                bufDualSenseUSB[4] = touchMotors && motorMask != 2 ? strong : 0
                bufDualSenseUSB[43] = touchLight ? brightness : 0
                bufDualSenseUSB[45] = touchLight ? red : 0
                bufDualSenseUSB[46] = touchLight ? green : 0
                bufDualSenseUSB[47] = touchLight ? blue : 0
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x02, bufDualSenseUSB, bufDualSenseUSB.count)
            } else if isDS && d.isBT {
                // 78-byte BT report: [0]=0x31, [1]=sequence<<4, [2]=0x10 tag,
                // then the SAME payload as USB starting at [3]. The old code
                // omitted the 0x10 tag byte, which shifted every field by one
                // and put the CRC at the wrong offset - the controller
                // silently discarded every packet, which is why the light
                // never changed over Bluetooth. Layout verified live: this
                // exact report turned the user's Edge blue.
                bufDualSenseBT[0] = 0x31
                sequenceTag = (sequenceTag &+ 1) & 0x0F
                bufDualSenseBT[1] = sequenceTag << 4
                bufDualSenseBT[2] = 0x10
                bufDualSenseBT[3] = touchMotors ? (vibrationMode == 2 ? 0x02 : 0x03) : 0x00  // valid_flag0: vibration + haptics select
                bufDualSenseBT[5] = touchMotors && motorMask != 1 ? weak : 0     // motor right (weak)
                bufDualSenseBT[6] = touchMotors && motorMask != 2 ? strong : 0   // motor left (strong)
                bufDualSenseBT[4] = touchLight ? 0x04 : 0x00   // valid_flag1: lightbar control
                // valid_flag2: lightbar setup (the first light write after
                // connect only), plus the newer vibration path when this
                // report carries motor values.
                bufDualSenseBT[41] = (setup ? 0x02 : 0x00) | (touchMotors && improvedRumble(pid: d.pid) ? 0x04 : 0x00)
                bufDualSenseBT[44] = setup ? 0x02 : 0x00  // lightbar_setup: fade out the connect light
                bufDualSenseBT[45] = touchLight ? brightness : 0
                bufDualSenseBT[47] = touchLight ? red : 0
                bufDualSenseBT[48] = touchLight ? green : 0
                bufDualSenseBT[49] = touchLight ? blue : 0
                let crc = Self.crc32(prefix: [0xA2], buffer: bufDualSenseBT, range: 0..<74)
                bufDualSenseBT[74] = UInt8(crc & 0xFF); bufDualSenseBT[75] = UInt8((crc >> 8) & 0xFF)
                bufDualSenseBT[76] = UInt8((crc >> 16) & 0xFF); bufDualSenseBT[77] = UInt8((crc >> 24) & 0xFF)
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x31, bufDualSenseBT, bufDualSenseBT.count)
            } else if Self.ds4PIDs.contains(d.pid) && !d.isBT {
                bufDS4USB[0] = 0x05
                // Bit 0 rumble, bit 1 LED color, bit 2 LED blink: claim
                // only the fields this write carries. Claiming rumble on
                // every light frame canceled any buzz within a frame.
                bufDS4USB[1] = (touchLight ? 0x06 : 0x00) | (touchMotors ? 0x01 : 0x00)
                bufDS4USB[6] = touchLight ? red : 0
                bufDS4USB[7] = touchLight ? green : 0
                bufDS4USB[8] = touchLight ? blue : 0
                bufDS4USB[4] = touchMotors ? weak : 0
                bufDS4USB[5] = touchMotors ? strong : 0
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x05, bufDS4USB, bufDS4USB.count)
            } else if Self.ds4PIDs.contains(d.pid) && d.isBT {
                // 78-byte DS4 BT report as SDL_hidapi_ps4.c sends it:
                // [0]=0x11, [1]=0xC0 (HID + CRC), [3] the effects this write
                // carries (bit 0 rumble, bit 1 light), motors at [6..7], RGB
                // at [8..10], CRC over [0..73] at [74..77]. Nothing else is
                // claimed: the volume flags this used to set wrote zero to
                // the headset and speaker volume on every write.
                bufDS4BT[0] = 0x11; bufDS4BT[1] = 0xC0; bufDS4BT[2] = 0x00; bufDS4BT[4] = 0x00
                bufDS4BT[6] = touchMotors ? weak : 0
                bufDS4BT[7] = touchMotors ? strong : 0
                bufDS4BT[3] = (touchLight ? 0x02 : 0x00) | (touchMotors ? 0x01 : 0x00)
                bufDS4BT[8] = touchLight ? red : 0
                bufDS4BT[9] = touchLight ? green : 0
                bufDS4BT[10] = touchLight ? blue : 0
                let crc = Self.crc32(prefix: [0xA2], buffer: bufDS4BT, range: 0..<74)
                bufDS4BT[74] = UInt8(crc & 0xFF); bufDS4BT[75] = UInt8((crc >> 8) & 0xFF)
                bufDS4BT[76] = UInt8((crc >> 16) & 0xFF); bufDS4BT[77] = UInt8((crc >> 24) & 0xFF)
                IOHIDDeviceSetReport(d.dev, kIOHIDReportTypeOutput, 0x11, bufDS4BT, bufDS4BT.count)
            }
        }
    }

    /// Precomputed CRC32 table - the old bit-serial loop did ~600 shifts per
    /// packet on every hold tick.
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1 != 0) ? (c >> 1) ^ 0xEDB88320 : c >> 1 }
        return c
    }

    /// CRC over `prefix` followed by `buffer[range]`, with zero heap
    /// allocations (the old call site concatenated two fresh arrays per tick,
    /// ~400 allocs/second per Bluetooth controller while holding a color).
    private static func crc32(prefix: [UInt8], buffer: [UInt8], range: Range<Int>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in prefix {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        for i in range {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(buffer[i])) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }
}
