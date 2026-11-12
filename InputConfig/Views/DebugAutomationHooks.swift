import SwiftUI
import SceneKit
import Metal
import GameController
import UniformTypeIdentifiers

// MARK: - Debug automation hooks (marketing / QA)

/// DEBUG-only view modifier that lets the app be driven from the shell via
/// DistributedNotificationCenter, so marketing captures and QA can navigate
/// without clicking. Wrapped in `#if DEBUG` so none of it can ship in a
/// Release build. Where a command needs a target preset, its name rides in
/// the notification's `object` (distributed notifications carry a string
/// object across processes).
///
/// Commands (post the name; pass the preset name as the object where noted):
///   inputconfig.debug.welcome            show the welcome screen
///   inputconfig.debug.select    <name>   select a preset (detail view)
///   inputconfig.debug.edit      [name]   open the binding editor
///   inputconfig.debug.activate  [name]   activate a preset (engine running)
///   inputconfig.debug.deactivate         stop the active preset
///   inputconfig.debug.sheet     <which>  smartmaker|stats|settings|motion|touchpad
///   inputconfig.debug.demo      <kind>   open a feature demo by raw value
///   inputconfig.debug.closesheets        dismiss any open sheet
///   inputconfig.debug.relaunch           press Restart Now (language restart)
/// See `dnc(_:)`: bridges distributed debug notifications to the local
/// center with immediate delivery, whatever app is in front.
@MainActor
final class DebugHookRelay: NSObject {
    static let shared = DebugHookRelay()
    private var names: Set<String> = []
    func ensure(_ name: String) {
        guard !names.contains(name) else { return }
        names.insert(name)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(relay(_:)), name: Notification.Name(name), object: nil,
            suspensionBehavior: .deliverImmediately)
    }
    func publisher(_ name: String) -> NotificationCenter.Publisher {
        ensure(name)
        return NotificationCenter.default.publisher(for: Notification.Name(name))
    }
    @objc private func relay(_ note: Notification) {
        let n = note
        Task { @MainActor in
            NotificationCenter.default.post(name: n.name, object: n.object, userInfo: n.userInfo)
        }
    }
}

#if DEBUG
/// DEBUG only: how many times the watched views' bodies ran, to count what
/// one event re-renders (a Scan, a live apply, a start, a recorded edge).
/// `post inputconfig.debug.bodycounts` writes the counts since the last
/// post to tmp/bodycounts.txt, one "name count" line each, and starts over.
@MainActor
enum BodyRuns {
    private static var counts: [String: Int] = [:]
    /// IC_PRINT_CHANGES set: the big bodies print what made them run
    /// (SwiftUI's _printChanges, to standard output).
    static func printChangesIfAsked() -> Bool { printChanges }
    private static let printChanges = ProcessInfo.processInfo.environment["IC_PRINT_CHANGES"] != nil
    private static var hook: NSObjectProtocol?

    static func note(_ name: String) {
        counts[name, default: 0] += 1
        guard hook == nil else { return }
        hook = NotificationCenter.default.addObserver(
            forName: Notification.Name("inputconfig.debug.bodycounts"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BodyRuns.write() }
        }
        DebugHookRelay.shared.ensure("inputconfig.debug.bodycounts")
    }

    /// The counts as lines, sorted by name, and a fresh start.
    @discardableResult
    static func write() -> String {
        let text = counts.keys.sorted().map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: "\n")
        counts.removeAll()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bodycounts.txt")
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        return text
    }
}
#endif

#if DEBUG
/// DEBUG only: the preset page's cards the page build probe leaves out, by
/// name ("header", "speed", "visualizer", "slots", "notes", "details"), so
/// each card's share of a switch is the page with it less the page without.
@MainActor
enum PageProbe {
    static var omitted: Set<String> = []
}

/// DEBUG only: what a preset switch costs the page to build and lay out.
/// Hosts the real PresetDetailView in an offscreen window at the given size,
/// switches through a sample of presets twice (the second lap is the one
/// counted, as the selection bench's warm lap), and times every main run loop
/// turn while the switch settles: the first turn is the switch's own frame,
/// any later turn is work it left for after the frame. Then the same with
/// each card left out. `post inputconfig.debug.pageprobe [WxH]` runs it in
/// the app and writes tmp/pageprobe.txt; a test program can call `run` too.
@MainActor
final class PageBuildProbe {
    @Observable @MainActor final class Selection { var id: UUID? }

    private struct Root: View {
        let store: PresetStore
        let selection: Selection
        let drafts: PresetPageDrafts
        let engine: MappingEngine
        let controllers: GameControllerService
        var body: some View {
            if let id = selection.id, let shown = store.presets.first(where: { $0.id == id }) {
                // Read only: the probe never writes a preset.
                PresetDetailView(preset: SwiftUI.Binding(get: { store.presets.first { $0.id == id } ?? shown },
                                                         set: { _ in }),
                                 pageDrafts: drafts, onEdit: {}, onToggle: {})
                    .environment(\.visualizerSuspended, false)
                    .environmentObject(engine)
                    .environmentObject(controllers)
                    .environmentObject(store)
            } else {
                Text("No preset")
            }
        }
    }

    /// Busy time of each main run loop turn, from waking to going back to
    /// sleep, as wall time and as the main thread's own CPU time (which
    /// other processes on a loaded Mac do not inflate).
    private final class TurnMeter {
        var started: CFAbsoluteTime = 0
        var startedCPU: Double = 0
        var turns: [Double] = []
        var turnsCPU: [Double] = []
        static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }
        var observers: [CFRunLoopObserver] = []
        /// Made in the turn that switches: that turn counts from here.
        init() {
            started = CFAbsoluteTimeGetCurrent()
            startedCPU = Self.cpu()
            let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [unowned self] _, _ in
                self.started = CFAbsoluteTimeGetCurrent()
                self.startedCPU = Self.cpu()
            }
            let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [unowned self] _, _ in
                if self.started > 0 {
                    self.turns.append((CFAbsoluteTimeGetCurrent() - self.started) * 1000)
                    self.turnsCPU.append(Self.cpu() - self.startedCPU)
                }
                self.started = 0
            }
            for o in [wake, sleep].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
                observers.append(o)
            }
        }
        func stop() { for o in observers { CFRunLoopObserverInvalidate(o) } }
    }

    struct Switch {
        var first = 0.0, worst = 0.0, total = 0.0, turns = 0, nsViews = 0
        var firstCPU = 0.0, worstCPU = 0.0, totalCPU = 0.0
    }

    static func countViews(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + countViews($1) } }
    /// The AppKit views under the page after the last switch, by class.
    static var lastViewClasses: [String: Int] = [:]
    /// Every AppKit view's class and frame in the window, per preset, from
    /// the counted lap: two builds that lay the page out the same give the
    /// same text (the controls' focus ring views mark where each one is).
    static var lastFrames: [UUID: String] = [:]
    /// The accessibility elements the page hands out, with their frames
    /// (with no assistive app running these are the AppKit ones: the notes
    /// editor, the scroll bars), a second check that a layout change moved
    /// nothing. Read only when asked (`dumpAccessibility`): reading it can
    /// make SwiftUI keep its accessibility tree up to date from then on,
    /// which would slow every later switch.
    static var dumpAccessibility = false
    static var lastAccessibility: [UUID: String] = [:]
    static func accessibility(_ e: Any, depth: Int = 0, into lines: inout [String]) {
        guard depth < 40 else { return }
        var role = "?", label = "", value = "", f = NSRect.zero, kids: [Any] = []
        if let v = e as? NSView {
            role = v.accessibilityRole()?.rawValue ?? "?"; label = v.accessibilityLabel() ?? ""
            value = v.accessibilityValue().map { "\($0)" } ?? ""; f = v.accessibilityFrame()
            kids = v.accessibilityChildren() ?? []
        } else if let a = e as? NSAccessibilityElement {
            role = a.accessibilityRole()?.rawValue ?? "?"; label = a.accessibilityLabel() ?? ""
            value = a.accessibilityValue().map { "\($0)" } ?? ""; f = a.accessibilityFrame()
            kids = a.accessibilityChildren() ?? []
        } else {
            return
        }
        lines.append(String(repeating: " ", count: depth) + "\(role) [\(label)] [\(value)] "
                     + String(format: "%.1f,%.1f %.1fx%.1f", f.minX, f.minY, f.width, f.height))
        for c in kids { accessibility(c, depth: depth + 1, into: &lines) }
    }
    static func frames(_ v: NSView, into lines: inout [String]) {
        let r = v.convert(v.bounds, to: nil)
        lines.append("\(type(of: v)) " + String(format: "%.1f,%.1f %.1fx%.1f", r.minX, r.minY, r.width, r.height))
        for s in v.subviews { frames(s, into: &lines) }
    }
    static func viewClasses(_ v: NSView, into counts: inout [String: Int]) {
        counts[String(describing: type(of: v)), default: 0] += 1
        for s in v.subviews { viewClasses(s, into: &counts) }
    }

    /// One configuration: every preset in `sample` shown twice, the second lap kept.
    static func lap(store: PresetStore, engine: MappingEngine, controllers: GameControllerService,
                    size: CGSize, sample: [Preset], settle: Double = 0.25) async -> [Switch] {
        let selection = Selection()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Root(store: store, selection: selection, drafts: PresetPageDrafts(),
                                                engine: engine, controllers: controllers))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        var kept: [Switch] = []
        for lapIndex in 0..<2 {
            for p in sample {
                let meter = TurnMeter()
                selection.id = p.id
                try? await Task.sleep(for: .seconds(settle))
                meter.stop()
                // The turn that set the selection is the first one counted.
                let turns = meter.turns.filter { $0 > 0.5 }
                let cpu = meter.turnsCPU.filter { $0 > 0.5 }
                guard lapIndex == 1 else { continue }
                var s = Switch()
                s.firstCPU = cpu.first ?? 0
                s.worstCPU = cpu.max() ?? 0
                s.totalCPU = cpu.reduce(0, +)
                s.first = turns.first ?? 0
                s.worst = turns.max() ?? 0
                s.total = turns.reduce(0, +)
                s.turns = turns.count
                s.nsViews = countViews(host)
                var classes: [String: Int] = [:]
                viewClasses(host, into: &classes)
                lastViewClasses = classes
                var lines: [String] = []
                frames(host, into: &lines)
                lastFrames[p.id] = lines.joined(separator: "\n")
                if dumpAccessibility {
                    var ax: [String] = []
                    accessibility(host, into: &ax)
                    lastAccessibility[p.id] = ax.joined(separator: "\n")
                }
                kept.append(s)
            }
        }
        return kept
    }

    /// The speed fields' text and their AppKit views after each preset is
    /// shown in turn, in one offscreen page: the bench's proof that a switch
    /// keeps the fields (the same views) and shows the new preset's speeds.
    static func speedFields(store: PresetStore, engine: MappingEngine, controllers: GameControllerService,
                            presets: [Preset]) async -> [(texts: [String], views: [ObjectIdentifier])] {
        let selection = Selection()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Root(store: store, selection: selection, drafts: PresetPageDrafts(),
                                                engine: engine, controllers: controllers))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func fields(_ v: NSView, into list: inout [NSTextField]) {
            if let f = v as? NSTextField, f.isEditable, f.stringValue.hasPrefix("\u{00D7}") == false,
               f.stringValue.range(of: #"^[0-9]+[.,][0-9]{2}$"#, options: .regularExpression) != nil {
                list.append(f)
            }
            for s in v.subviews { fields(s, into: &list) }
        }
        var out: [(texts: [String], views: [ObjectIdentifier])] = []
        for p in presets {
            selection.id = p.id
            try? await Task.sleep(for: .seconds(0.35))
            var list: [NSTextField] = []
            fields(host, into: &list)
            out.append((list.map(\.stringValue), list.map { ObjectIdentifier($0) }))
        }
        return out
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The whole page, then the page less each card, in turn, `rounds`
    /// times (a loaded Mac drifts; taking each configuration in every round
    /// spreads the drift over all of them). Medians in ms.
    static func run(store: PresetStore, engine: MappingEngine, controllers: GameControllerService,
                    size: CGSize, count: Int = 12, rounds: Int = 3,
                    cards: [String] = ["header", "speed", "visualizer", "slots", "notes", "details"]) async -> String {
        let all = store.presetsInSidebarOrder
        let step = max(1, all.count / max(1, count))
        let sample = Array(stride(from: 0, to: all.count, by: step).map { all[$0] }.prefix(count))
        var lines = ["page probe \(Int(size.width))x\(Int(size.height)), \(sample.count) presets, warm lap, \(rounds) rounds, ms (median per switch)",
                     "wall: first turn, worst turn, all turns; cpu: the main thread's own time, same three",
                     "config            first  worst  total | cpu first  worst  total | turns  nsviews"]
        let configs: [(String, Set<String>)] = [("full page", [])] + cards.map { ("without \($0)", [$0]) }
        var results: [String: [Switch]] = [:]
        for _ in 0..<max(1, rounds) {
            for (name, omitted) in configs {
                PageProbe.omitted = omitted
                results[name, default: []] += await lap(store: store, engine: engine, controllers: controllers,
                                                         size: size, sample: sample)
            }
        }
        PageProbe.omitted = []
        var medians: [String: (Double, Double, Double)] = [:]
        for (name, _) in configs {
            let r = results[name] ?? []
            let f = median(r.map(\.first)), w = median(r.map(\.worst)), t = median(r.map(\.total))
            let cf = median(r.map(\.firstCPU)), cw = median(r.map(\.worstCPU)), ct = median(r.map(\.totalCPU))
            let turns = median(r.map { Double($0.turns) }), views = median(r.map { Double($0.nsViews) })
            lines.append(name.padding(toLength: 16, withPad: " ", startingAt: 0)
                         + String(format: "%7.1f%7.1f%7.1f |%10.1f%7.1f%7.1f |%6.1f%9.0f", f, w, t, cf, cw, ct, turns, views))
            medians[name] = (cf, cw, ct)
        }
        if let full = medians["full page"], !cards.isEmpty {
            lines.append("card cost (full less without, cpu):")
            for card in cards {
                guard let less = medians["without \(card)"] else { continue }
                lines.append(String(format: "  %@: first %.1f, worst %.1f, total %.1f", card,
                                    full.0 - less.0, full.1 - less.1, full.2 - less.2))
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif

extension View {
    /// DEBUG only: a page card the page build probe can leave out. Release
    /// builds get the view unchanged.
    @ViewBuilder
    func pageProbeCard(_ name: String) -> some View {
        #if DEBUG
        if !PageProbe.omitted.contains(name) { self }
        #else
        self
        #endif
    }
}

struct DebugAutomationHooks: ViewModifier {
    let presetStore: PresetStore
    /// Only the debug state readout uses this; it reports what the app is
    /// seeing from the hardware.
    @EnvironmentObject var controllerService: GameControllerService
    /// The selection object, not a Binding: making a Binding in the
    /// window's body read the selection there, so every switch re-ran the
    /// whole window and rebuilt the page and visualizer once more (seen
    /// with _printChanges).
    let selection: PresetSelection
    var selectedPresetId: UUID? {
        get { selection.id }
        nonmutating set { selection.id = newValue }
    }
    @Binding var editingPreset: Preset?
    @Binding var showingSmartMaker: Bool
    @Binding var showingStats: Bool
    @Binding var settingsSheetTab: SettingsView.SettingsTab?
    @Binding var showingMotion: Bool
    @Binding var showingTouchpad: Bool
    @Binding var presentedDemoKind: FeatureDemoKind?
    let onToggle: (Preset) -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onReceive(dnc("inputconfig.debug.welcome")) { _ in
                editingPreset = nil
                selectedPresetId = nil
            }
            // inputconfig.debug.zones touchpad|screen|stick0|stick1|band4: the
            // open editor's first group shows that part's zones.
            // inputconfig.debug.dumpsheet: the views over the top of the
            // deepest sheet, to tmp/sheetviews.txt.
            .onReceive(dnc("inputconfig.debug.dumpsheet")) { _ in
                var top = NSApp.windows.first { $0.isVisible && $0.attachedSheet != nil }?.attachedSheet
                while let next = top?.attachedSheet { top = next }
                guard let win = top, let root = win.contentView?.superview else { return }
                var lines = ["window \(type(of: win)) transparentTitle=\(win.titlebarAppearsTransparent) style=\(win.styleMask.rawValue)"]
                func walk(_ v: NSView, _ depth: Int) {
                    let f = v.convert(v.bounds, to: nil)
                    if f.maxY > win.frame.height - 110 || depth < 3 {
                        let bg = v.layer?.backgroundColor.map { "\($0)" } ?? "-"
                        let fx = (v as? NSVisualEffectView).map { " material=\($0.material.rawValue) state=\($0.state.rawValue) blend=\($0.blendingMode.rawValue)" } ?? ""
                        lines.append(String(repeating: "  ", count: depth) + "\(type(of: v)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) hidden=\(v.isHidden) alpha=\(v.alphaValue) bg=\(bg)\(fx)")
                    }
                    for sub in v.subviews { walk(sub, depth + 1) }
                }
                walk(root, 0)
                try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sheetviews.txt"), atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.zones")) { note in
                let raw = (note.object as? String) ?? "touchpad"
                let part: ZonePart = raw == "screen" ? .screen
                    : raw.hasPrefix("stick") ? .stick(raw == "stick1" ? 1 : 0)
                    : raw.hasPrefix("band") ? .band(Int(raw.dropFirst(4)) ?? 4) : .touchpad
                ShowZonesRequest(groupIndex: 0, part: part).post()
            }
            // Selects every preset in turn and writes how long the main thread
            // stalled for each, read from a 1 ms timer that cannot fire while
            // main is busy.
            .onReceive(dnc("inputconfig.debug.selectbench")) { note in
                let cold = (note.object as? String) == "cold"
                Task { @MainActor in
                    var lines: [String] = []
                    // The second lap is what is written: the first look at a
                    // preset fills the drawing's caches. "cold" writes the first.
                    let laps = cold ? 1 : 2
                    for lap in 1...laps {
                    lines = []
                    _ = lap
                    for p in presetStore.presetsInSidebarOrder {
                        var last = CACurrentMediaTime(), worst = 0.0, busy = 0.0
                        let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
                            let now = CACurrentMediaTime(), gap = now - last
                            last = now
                            worst = max(worst, gap)
                            if gap > 0.008 { busy += gap }
                        }
                        RunLoop.main.add(timer, forMode: .common)
                        selectedPresetId = p.id
                        try? await Task.sleep(for: .seconds(0.4))
                        timer.invalidate()
                        lines.append(String(format: "%6.0f %6.0f  %@", worst * 1000, busy * 1000, p.name))
                    }
                    }
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selectbench.txt")
                    try? (lines.joined(separator: "\n") + "\ndone\n").write(to: url, atomically: true, encoding: .utf8)
                }
            }
            .onReceive(dnc("inputconfig.debug.select")) { note in
                if let p = preset(note) {
                    editingPreset = nil
                    selectedPresetId = p.id
                }
            }
            .onReceive(dnc("inputconfig.debug.edit")) { note in
                if let p = preset(note) ?? selected() {
                    selectedPresetId = p.id
                    editingPreset = p
                }
            }
            .onReceive(dnc("inputconfig.debug.activate")) { note in
                if let p = preset(note) ?? selected() {
                    selectedPresetId = p.id
                    if !p.isActive { onToggle(p) }
                }
            }
            #if DEBUG
            .onReceive(dnc("inputconfig.debug.buzz")) { _ in
                if let c = controllerService.connectedControllers.first {
                    FeedbackService.shared.debugBuzzTest(controller: c)
                }
            }
            #endif
            .onReceive(dnc("inputconfig.debug.deactivate")) { _ in
                if let active = presetStore.presets.first(where: { $0.isActive }) {
                    onToggle(active)
                }
            }
            .onReceive(dnc("inputconfig.debug.sheet")) { note in
                closeSheets()
                editingPreset = nil
                switch note.object as? String {
                case "smartmaker": showingSmartMaker = true
                case "stats": showingStats = true
                case "settings": settingsSheetTab = .general
                case "about": settingsSheetTab = .about
                case "advanced": settingsSheetTab = .advanced
                case "devices": settingsSheetTab = .controllers
                // Exercises the exact call the Help window's "here" link makes,
                // so the cross-window path can be tested without pixel-clicking
                // a link in a window that keeps losing front position.
                case "aboutlink": MenuBarController.shared.openAboutPage()
                case "motion": showingMotion = true
                case "touchpad": showingTouchpad = true
                default: break
                }
            }
            .onReceive(dnc("inputconfig.debug.demo")) { note in
                closeSheets()
                if let raw = note.object as? String,
                   let kind = FeatureDemoKind(rawValue: raw) {
                    presentedDemoKind = kind
                }
            }
            .onReceive(dnc("inputconfig.debug.closesheets")) { _ in
                closeSheets()
            }
            // Restart Now, as Settings, General, Language presses it.
            .onReceive(dnc("inputconfig.debug.relaunch")) { _ in
                AppLanguage.relaunch()
            }
            .onReceive(dnc("inputconfig.debug.printpdf")) { note in
                // The printed page of a preset, to tmp/print.pdf.
                if let p = preset(note) ?? selected() {
                    PresetPrint.savePDF(p, controllers: controllerService,
                                        to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("print.pdf"))
                }
            }
            .onReceive(dnc("inputconfig.debug.simpleshot")) { _ in
                // Simple View offscreen, to tmp/simple.png.
                let renderer = ImageRenderer(content:
                    SimpleLauncherView(onToggle: { _ in }, onLeave: {})
                        .environmentObject(presetStore)
                        .environmentObject(controllerService)
                        .frame(width: 1200, height: 800))
                renderer.scale = 1
                if let cg = renderer.cgImage,
                   let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simple.png"))
                }
            }
            .onReceive(dnc("inputconfig.debug.renderdemos")) { _ in
                // Offscreen frames of every feature demo, three per demo
                // 0.6 s apart, into the sandbox tmp: a way to review the
                // animations without the window being on screen.
                Task { @MainActor in
                    for kind in FeatureDemoKind.allCases {
                        for i in 0..<3 {
                            let renderer = ImageRenderer(content:
                                FeatureDemoView(kind: kind, onJumpToPreset: { _ in }, onOpenStatistics: {}, onOpenSettings: {})
                                    .frame(width: 560, height: 500)
                                    .background(Color(nsColor: .windowBackgroundColor))
                                    .environment(\.colorScheme, .dark))
                            renderer.scale = 2
                            if let cg = renderer.cgImage {
                                let rep = NSBitmapImageRep(cgImage: cg)
                                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("demo_\(kind.rawValue)_\(i).png")
                                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                            }
                            try? await Task.sleep(nanoseconds: 600_000_000)
                        }
                    }
                }
            }
            .onReceive(dnc("inputconfig.debug.tour")) { note in
                // "start", "back", "stop", or anything else for Next.
                switch note.object as? String {
                case "start": NotificationCenter.default.post(name: .inputConfigStartTutorial, object: nil)
                case "back": TutorialState.shared.back()
                case "stop": TutorialState.shared.stop()
                default: TutorialState.shared.next()
                }
            }
            .onReceive(dnc("inputconfig.debug.review")) { _ in
                ReviewPromptService.shared.present()
            }
            .onReceive(dnc("inputconfig.debug.whatsnew")) { _ in
                // Exercises the real menu bar path: open the window, post
                // the request, let ContentView's observer present it.
                MenuBarController.shared.showWhatsNew()
            }
            .onReceive(dnc("inputconfig.debug.injecttap")) { note in
                // "<count>" or "<count>,<spacing ms>"
                let parts = ((note.object as? String) ?? "").split(separator: ",")
                let n = Int(parts.first ?? "") ?? 2
                let ms = parts.count > 1 ? (Double(parts[1]) ?? 150) : 150
                ChassisTapService.shared.injectSyntheticTaps(count: n, spacing: ms / 1000)
            }
            .onReceive(dnc("inputconfig.debug.scan")) { _ in
                NotificationCenter.default.post(
                    name: PresetEditorView.debugStartScanNotification, object: nil)
            }
            .onReceive(dnc("inputconfig.debug.presetorder")) { _ in
                var out = ""
                for g in presetStore.groups.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    out += "[\(g.name)]\n"
                    for p in presetStore.presets(in: g.id) {
                        out += "   \(p.sortOrder.map(String.init) ?? "-")  \(p.name)\n"
                    }
                }
                out += "[My Presets]\n"
                for p in presetStore.presets(in: nil) {
                    out += "   \(p.sortOrder.map(String.init) ?? "-")  \(p.name)\n"
                }
                try? out.write(toFile: NSTemporaryDirectory() + "presetorder.txt",
                               atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.movepreset")) { note in
                // "<dragged preset>,<target preset>" - exercises the exact
                // store call the row's dropDestination makes.
                let parts = ((note.object as? String) ?? "").split(separator: ",")
                guard parts.count == 2,
                      let drag = presetStore.presets.first(where: { $0.name == String(parts[0]) }),
                      let target = presetStore.presets.first(where: { $0.name == String(parts[1]) })
                else { return }
                presetStore.movePreset(drag.id, toPositionOf: target.id)
            }
            .onReceive(dnc("inputconfig.debug.tapstrikes")) { _ in
                try? ChassisTapService.shared.drainStrikes()
                    .write(toFile: NSTemporaryDirectory() + "tapstrikes.txt",
                           atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.tapcommits")) { _ in
                try? (ChassisTapService.shared.drainCommits() + "\n")
                    .write(toFile: NSTemporaryDirectory() + "tapcommits.txt",
                           atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.taptrace")) { note in
                let secs = Double((note.object as? String) ?? "") ?? 8
                ChassisTapService.shared.startTrace(seconds: secs,
                    path: NSTemporaryDirectory() + "taptrace.txt")
            }
            .onReceive(dnc("inputconfig.debug.tapstats")) { _ in
                let d = ChassisTapService.shared.drainDiagnostics()
                let line = "denied=\(ChassisTapService.shared.wakeDenied) reports=\(d.reports) strikes=\(d.strikes) peak=\(String(format: "%.4f", d.peak))g noise=\(String(format: "%.4f", d.noise))g ready=\(d.ready) running=\(ChassisTapService.shared.isRunning) error=\(ChassisTapService.shared.lastError ?? "none") reasons=\(ChassisTapService.shared.activeReasons)"
                try? line.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("tapstats.txt"), atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.systemaction")) { note in
                if let raw = note.object as? String,
                   let kind = SystemActionKind(rawValue: raw) {
                    SystemActionService.shared.perform(kind, parameter: nil)
                }
            }
            // Can this build actually read your Shortcuts and applications?
            // The sandbox decides, so it has to be measured, not assumed.
            .onReceive(dnc("inputconfig.debug.lists")) { _ in
                SystemListsCache.shared.refreshIfStale()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let c = SystemListsCache.shared
                    let text = "shortcuts=\(c.shortcuts.count) apps=\(c.apps.count)\n"
                        + "first shortcuts: \(c.shortcuts.prefix(5).joined(separator: ", "))\n"
                        + "first apps: \(c.apps.prefix(5).joined(separator: ", "))\n"
                    try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("lists.txt"), atomically: true, encoding: .utf8)
                }
            }
            // What the light writer is holding, and what the slot is meant
            // to be showing. "peek" reports without firing anything.
            .onReceive(dnc("inputconfig.debug.light")) { note in
                let arg = (note.object as? String) ?? ""
                let peek = arg == "peek" || arg == "default"
                // "default" runs the slot-default path that used to steal the
                // preset's color, so the fix can be proved without a replug.
                if arg == "default" { controllerService.setControllerLight(at: 0) }
                if !peek, let c = controllerService.connectedControllers.first {
                    FeedbackService.shared.vibrate(controller: c, intensity: 0.8, durationMs: 1500)
                }
                let delay: Double = peek ? 0.0 : 0.4
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let writer: String = InProcessLightWriter.shared.debugState
                    let details = controllerService.controllerDetails[0]
                    let hasLight: String = details.map { String($0.hasLight) } ?? "no slot 0"
                    let stored = controllerService.lightColors[0]
                    let storedText: String = stored.map { "(\($0.r),\($0.g),\($0.b))" } ?? "none"
                    var lines: [String] = []
                    lines.append("writer: " + writer)
                    lines.append("slot 0 hasLight: " + hasLight)
                    let gcLight = controllerService.connectedControllers.first?.light
                    let gcColor = gcLight.map { l in
                        String(format: "(%.0f,%.0f,%.0f)", l.color.red * 255, l.color.green * 255, l.color.blue * 255)
                    } ?? "nil"
                    lines.append("GCDeviceLight: \(gcLight == nil ? "not supported" : "supported") color \(gcColor)")
                    lines.append("slot 0 stored color: " + storedText)
                    lines.append("detail slots: \(Array(controllerService.controllerDetails.keys).sorted())")
                    lines.append("temp light calls: \(controllerService.debugTempLightLog)")
                    let act = presetStore.presets.first { $0.isActive }
                    let actColor = act?.lightBarColor.map { "(\($0.r),\($0.g),\($0.b))" } ?? "none"
                    lines.append("active preset: \(act?.name ?? "none") color \(actColor)")
                    let text: String = lines.joined(separator: "\n") + "\n"
                    try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("light.txt"), atomically: true, encoding: .utf8)
                }
            }
            // Drive a finger across the pad through the same entry point the
            // controller feeds, and report whether the pointer actually
            // moved. Tests the whole chain with no hardware in the loop.
            .onReceive(dnc("inputconfig.debug.swipe")) { note in
                // "<ms>": a sustained circular finger motion for that long,
                // at the pad's own 250 Hz, for profiling under load.
                if let ms = Int((note.object as? String) ?? ""), ms > 0 {
                    let steps = ms / 4
                    for i in 0...steps {
                        let t = Double(i) / 250.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.004) {
                            TouchpadService.shared.ingestGameControllerTouchpad(
                                f0Active: i < steps,
                                f0NormalizedX: Float(0.5 * sin(t * 2.5)), f0NormalizedY: Float(0.4 * cos(t * 2.5)),
                                f1Active: false, f1NormalizedX: 0, f1NormalizedY: 0)
                        }
                    }
                    return
                }
                let start = NSEvent.mouseLocation
                var lines: [String] = ["start cursor \(Int(start.x)),\(Int(start.y))"]
                let steps = 30
                for i in 0...steps {
                    let t = Float(i) / Float(steps)
                    let x = -0.6 + 1.2 * t          // left edge to right edge
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.012) {
                        TouchpadService.shared.ingestGameControllerTouchpad(
                            f0Active: true, f0NormalizedX: x, f0NormalizedY: 0.1,
                            f1Active: false, f1NormalizedX: 0, f1NormalizedY: 0)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps) * 0.012 + 0.05) {
                    let mid = NSEvent.mouseLocation
                    lines.append("after swipe cursor \(Int(mid.x)),\(Int(mid.y))")
                    lines.append("moved dx=\(Int(mid.x - start.x)) dy=\(Int(mid.y - start.y))")
                    lines.append("fingerActive=\(TouchpadService.shared.isFingerActive(0))")
                    lines.append("peekDelta x=\(TouchpadService.shared.peekDelta(finger: 0, axis: .x))")
                    lines.append("samples=\(TouchpadService.shared.gameControllerSampleCount)")
                    TouchpadService.shared.ingestGameControllerTouchpad(
                        f0Active: false, f0NormalizedX: 0, f0NormalizedY: 0,
                        f1Active: false, f1NormalizedX: 0, f1NormalizedY: 0)
                    let text = lines.joined(separator: "\n") + "\n"
                    try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("swipe.txt"), atomically: true, encoding: .utf8)
                }
            }
            // Watch the raw gyro for a few seconds and report which axis a
            // movement lands on: "<ms>". Settles axis conventions by
            // measurement instead of by documentation.
            .onReceive(dnc("inputconfig.debug.gyrowatch")) { note in
                let ms = Int((note.object as? String) ?? "") ?? 4000
                var peak = SIMD3<Float>(0, 0, 0)
                var sumSigned = SIMD3<Float>(0, 0, 0)
                var accelMin = SIMD3<Float>(9, 9, 9), accelMax = SIMD3<Float>(-9, -9, -9)
                let ticks = max(1, ms / 33)
                for i in 0...ticks {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.033) {
                        guard let c = controllerService.connectedControllers.first, let m = c.motion else { return }
                        let r = SIMD3(Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z))
                        peak = SIMD3(max(peak.x, abs(r.x)), max(peak.y, abs(r.y)), max(peak.z, abs(r.z)))
                        sumSigned += r * 0.033
                        let a = SIMD3(Float(m.acceleration.x), Float(m.acceleration.y), Float(m.acceleration.z))
                        accelMin = SIMD3(min(accelMin.x, a.x), min(accelMin.y, a.y), min(accelMin.z, a.z))
                        accelMax = SIMD3(max(accelMax.x, a.x), max(accelMax.y, a.y), max(accelMax.z, a.z))
                        if i == ticks {
                            let text = String(format: "peak rate  x=%.2f y=%.2f z=%.2f rad/s\nnet turn   x=%+.2f y=%+.2f z=%+.2f rad\naccel span x=%.2f y=%.2f z=%.2f g\n",
                                              peak.x, peak.y, peak.z, sumSigned.x, sumSigned.y, sumSigned.z,
                                              accelMax.x - accelMin.x, accelMax.y - accelMin.y, accelMax.z - accelMin.z)
                            try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                                .appendingPathComponent("gyrowatch.txt"), atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
            // Snapshot every SceneKit view on screen (the gyro controller
            // model) to gyro-N.png, so its look can be judged from outside.
            .onReceive(dnc("inputconfig.debug.gyrosnap")) { _ in
                func walk(_ v: NSView, _ out: inout [SCNView]) {
                    if let s = v as? SCNView { out.append(s) }
                    for c in v.subviews { walk(c, &out) }
                }
                var found: [SCNView] = []
                for w in NSApp.windows where w.isVisible { if let cv = w.contentView { walk(cv, &found) } }
                for (i, v) in found.enumerated() {
                    // Rendered large, off screen, so detail can be judged.
                    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                    renderer.scene = v.scene
                    renderer.pointOfView = v.pointOfView
                    renderer.autoenablesDefaultLighting = v.autoenablesDefaultLighting
                    if renderer.pointOfView == nil {
                        renderer.pointOfView = v.scene?.rootNode.childNodes(passingTest: { n, _ in n.camera != nil }).first
                    }
                    let img = renderer.snapshot(atTime: 0, with: CGSize(width: 1200, height: 800), antialiasingMode: .multisampling4X)
                    try? "\(found.count) scene views; image \(img.size) pov \(renderer.pointOfView != nil) lighting \(v.autoenablesDefaultLighting)\n".write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gyrosnap.txt"), atomically: true, encoding: .utf8)
                    guard let tiff = img.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { continue }
                    try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gyro-\(i).png"))
                }
            }
            // Size of the sheet in front, so a run over every showcase can
            // prove they all present at one size.
            // `post inputconfig.debug.auditpresets` checks every built-in
            // example and every Smart Preset profile mechanically and writes
            // tmp/audit.txt: inputs and outputs that fail to parse, rows that
            // send nothing, notes tables that name rows or presets that do
            // not exist, duplicate names, and profiles with no usable rows.
            .onReceive(dnc("inputconfig.debug.auditpresets")) { _ in
                var out: [String] = []
                let all = ExamplePresets.all
                let names = all.map(\.name)
                let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
                if !dupes.isEmpty { out.append("DUPLICATE example names: \(dupes)") }
                for p in all {
                    var rowKeys: Set<String> = []
                    for g in p.joysticks {
                        for b in g.bindings {
                            let key = b.input.serialized
                            rowKeys.insert(key)
                            if InputEvent.parse(key)?.serialized != key { out.append("\(p.name): input does not round-trip: \(key)") }
                            let fires = !b.outputs.isEmpty || !(b.holdOutputs ?? []).isEmpty || !(b.doubleTapOutputs ?? []).isEmpty || !(b.tripleTapOutputs ?? []).isEmpty
                                || !(b.macroSteps ?? []).isEmpty || b.hapticEnabled == true || b.speechEnabled == true
                            if !fires { out.append("\(p.name): row sends nothing: \(key)") }
                            for o in b.outputs where OutputAction.parse(o.serialized)?.serialized != o.serialized {
                                out.append("\(p.name): output does not round-trip: \(o.serialized)")
                            }
                        }
                    }
                    if let notes = ExamplePresets.rowNotes[p.name] {
                        for k in notes.keys where !rowKeys.contains(k) { out.append("\(p.name): rowNotes names a row it does not have: \(k)") }
                    }
                    if ExamplePresets.presetNotes[p.name] == nil { out.append("\(p.name): no presetNotes entry") }
                    if ExamplePresets.groupAssignments[p.name] == nil { out.append("\(p.name): no group assignment") }
                }
                for k in ExamplePresets.rowNotes.keys where !names.contains(k) { out.append("rowNotes for unknown preset: \(k)") }
                for k in ExamplePresets.presetNotes.keys where !names.contains(k) { out.append("presetNotes for unknown preset: \(k)") }
                for k in ExamplePresets.groupAssignments.keys where !names.contains(k) { out.append("groupAssignments for unknown preset: \(k)") }
                for (k, v) in ExamplePresets.demoPresetNames where !names.contains(v) { out.append("demoPresetNames \(k) points at unknown preset: \(v)") }
                for kind in FeatureDemoKind.allCases {
                    if let key = kind.presetKey, ExamplePresets.demoPresetNames[key] == nil { out.append("showcase \(kind.rawValue) has no demo preset for key \(key)") }
                }
                let lib = SmartPresetLibrary.all
                let ids = lib.map(\.id)
                let dupIDs = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
                if !dupIDs.isEmpty { out.append("DUPLICATE smart profile ids: \(dupIDs)") }
                var smartRows = 0
                for prof in lib {
                    var usable = 0
                    for b in prof.bindings {
                        if InputEvent.parse(b.input) == nil { out.append("smart \(prof.id): bad input \(b.input)") ; continue }
                        let outs = b.outputs.compactMap { OutputAction.parse($0) }
                        if outs.isEmpty { out.append("smart \(prof.id): row with no usable output: \(b.input) \(b.outputs)"); continue }
                        if outs.count != b.outputs.count { out.append("smart \(prof.id): some outputs failed to parse: \(b.input) \(b.outputs)") }
                        if b.note.trimmingCharacters(in: .whitespaces).isEmpty { out.append("smart \(prof.id): row without a note: \(b.input)") }
                        usable += 1
                    }
                    smartRows += usable
                    if usable == 0 { out.append("smart \(prof.id): NO usable rows") }
                    if prof.displayName.isEmpty { out.append("smart \(prof.id): empty display name") }
                    if !prof.appPath.isEmpty && !prof.appPath.hasSuffix(".app") { out.append("smart \(prof.id): odd appPath \(prof.appPath)") }
                    let inputs = prof.bindings.map(\.input)
                    let dupIn = Dictionary(grouping: inputs, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
                    if !dupIn.isEmpty { out.append("smart \(prof.id): input bound twice: \(dupIn)") }
                }
                out.insert("examples=\(all.count) smartProfiles=\(lib.count) smartRows=\(smartRows) findings=\(out.count)", at: 0)
                let text = out.joined(separator: "\n") + "\n"
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audit.txt"), atomically: true, encoding: .utf8)
            }
            // `post inputconfig.debug.rumblerig` plays ten variants in a row,
            // each announced by a light-bar color, each a 100% buzz then a
            // 20% buzz, and writes the color key to tmp/rig.txt. For
            // finding which part of the path is flattening the strength.
            .onReceive(dnc("inputconfig.debug.rumblerig")) { _ in
                let writer = InProcessLightWriter.shared
                let pad = controllerService.connectedControllers.first
                struct Variant { let name: String; let color: (UInt8, UInt8, UInt8); let setup: () -> Void; let buzz: (Float) -> Void }
                func plain(_ i: Float) { writer.vibrate(intensity: i, durationMs: 500) }
                let variants: [Variant] = [
                    Variant(name: "1 red: both flags, both motors (shipped)", color: (255, 0, 0),
                            setup: { InProcessLightWriter.debugVibrationMode = 0; InProcessLightWriter.debugMotorMask = 0 }, buzz: plain),
                    Variant(name: "2 orange: older flag only", color: (255, 110, 0),
                            setup: { InProcessLightWriter.debugVibrationMode = 1 }, buzz: plain),
                    Variant(name: "3 yellow: newer flag only", color: (255, 220, 0),
                            setup: { InProcessLightWriter.debugVibrationMode = 2 }, buzz: plain),
                    Variant(name: "4 green: strong (left) motor only", color: (0, 255, 0),
                            setup: { InProcessLightWriter.debugVibrationMode = 0; InProcessLightWriter.debugMotorMask = 1 }, buzz: plain),
                    Variant(name: "5 cyan: weak (right) motor only", color: (0, 220, 255),
                            setup: { InProcessLightWriter.debugMotorMask = 2 }, buzz: plain),
                    Variant(name: "6 blue: pulsed bursts 60 on 40 off", color: (0, 60, 255),
                            setup: { InProcessLightWriter.debugMotorMask = 0 }, buzz: { i in
                                for k in 0..<5 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.1) { writer.vibrate(intensity: i, durationMs: 60) } }
                            }),
                    Variant(name: "7 purple: Apple light write right before", color: (170, 0, 255),
                            setup: {}, buzz: { i in
                                pad?.light?.color = GCColor(red: 0.67, green: 0, blue: 1)
                                writer.vibrate(intensity: i, durationMs: 500)
                            }),
                    Variant(name: "8 pink: 1500 ms long", color: (255, 60, 160),
                            setup: {}, buzz: { i in writer.vibrate(intensity: i, durationMs: 1500) }),
                    Variant(name: "9 white: Apple haptics (reference, repaints light)", color: (255, 255, 255),
                            setup: {}, buzz: { i in
                                if let pad { FeedbackService.shared.vibrateViaHaptics(controller: pad, intensity: i, durationMs: 500) }
                                // The engine must not outlive the buzz: while one exists the
                                // system holds the pad's output stream and flattens our motors.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { FeedbackService.shared.clearHapticEngines() }
                            }),
                    Variant(name: "10 teal: shipped path again (control)", color: (0, 180, 160),
                            setup: { InProcessLightWriter.debugVibrationMode = 0; InProcessLightWriter.debugMotorMask = 0 }, buzz: plain),
                ]
                var key = "Each variant: color, then 100% for the buzz, then 20%. Variants 3.6 s apart.\n"
                for (n, v) in variants.enumerated() {
                    let t0 = Double(n) * (v.name.hasPrefix("8") ? 4.6 : 3.6)
                    key += v.name + "\n"
                    DispatchQueue.main.asyncAfter(deadline: .now() + t0) { NSLog("[RIG] %@", v.name); v.setup(); writer.startHold(red: v.color.0, green: v.color.1, blue: v.color.2) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + t0 + 0.7) { v.buzz(1.0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + t0 + 2.0) { v.buzz(0.2) }
                }
                let total = Double(variants.count) * 3.6 + 2.5
                DispatchQueue.main.asyncAfter(deadline: .now() + total) {
                    InProcessLightWriter.debugVibrationMode = 0; InProcessLightWriter.debugMotorMask = 0
                    NSLog("[RIG] done")
                }
                try? key.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rig.txt"), atomically: true, encoding: .utf8)
            }
            // `post inputconfig.debug.buzzlevel <0-100>` runs the pad's motors
            // at that strength for 700 ms through the app's own report, and
            // writes the light writer's state to tmp/light.txt, so a strength
            // that feels wrong can be measured level by level.
            .onReceive(dnc("inputconfig.debug.buzzlevel")) { note in
                // "<pct>" or "<pct> both|legacy|new" to pick the vibration flags.
                let parts = ((note.object as? String) ?? "").split(separator: " ").map(String.init)
                let pct = Int(parts.first ?? "") ?? 100
                if pct < 0 {
                    // A dump only, no buzz.
                    let text = InProcessLightWriter.shared.debugState + "\n"
                    try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("light.txt"), atomically: true, encoding: .utf8)
                    return
                }
                if parts.count > 1, parts[1] == "apple" {
                    // Apple's haptics engine on the same pad, for comparison.
                    if let pad = controllerService.connectedControllers.first {
                        FeedbackService.shared.vibrateViaHaptics(controller: pad, intensity: Float(max(0, min(100, pct))) / 100, durationMs: 700)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { FeedbackService.shared.clearHapticEngines() }
                    }
                    return
                }
                if parts.count > 1 {
                    InProcessLightWriter.debugVibrationMode = parts[1] == "legacy" ? 1 : (parts[1] == "new" ? 2 : 0)
                }
                InProcessLightWriter.shared.vibrate(intensity: Float(max(0, min(100, pct))) / 100, durationMs: 700)
                let text = "level=\(pct)\n" + InProcessLightWriter.shared.debugState + "\n"
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("light.txt"), atomically: true, encoding: .utf8)
            }
            // `post inputconfig.debug.extstate` writes the keyboard / mouse
            // monitor's state to tmp/extstate.txt: permission, who holds
            // which monitor, and the live input set.
            .onReceive(dnc("inputconfig.debug.extstate")) { _ in
                let text = ExternalInputDeviceService.shared.debugState + "\n" + LiveRowLights.shared.debugState + "\n"
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("extstate.txt"), atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.sheetsize")) { _ in
                var sheet = NSApp.keyWindow
                while let s = sheet?.attachedSheet { sheet = s }
                let size = sheet?.frame.size ?? .zero
                let text = String(format: "%.0f x %.0f\n", size.width, size.height)
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sheetsize.txt"), atomically: true, encoding: .utf8)
            }
            // Write the 3D controller model out as a file that Quick Look
            // and any 3D tool can open, so it can be judged outside the app.
            .onReceive(dnc("inputconfig.debug.exportmodel")) { _ in
                let scene = SCNScene()
                let satin = SCNMaterial()
                satin.lightingModel = .physicallyBased
                satin.diffuse.contents = NSColor(white: 0.93, alpha: 1)
                satin.roughness.contents = 0.38
                let node = GlyphSolid.node(path: ControllerGlyphPath.bezier(), depth: 0.22, material: satin)
                scene.rootNode.addChildNode(node)
                let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                let usdz = dir.appendingPathComponent("controller.usdz")
                let ok = scene.write(to: usdz, options: nil, delegate: nil, progressHandler: nil)
                let stl = dir.appendingPathComponent("controller.stl")
                let okSTL = GlyphSolid.writeSTL(path: ControllerGlyphPath.bezier(), depth: 0.22, to: stl)
                try? "usdz=\(ok) stl=\(okSTL)\n".write(to: dir.appendingPathComponent("exportmodel.txt"), atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.panic")) { _ in
                EmergencyStopService.shared.stop(reason: .menu)
            }
            // Press and release one keyboard output by HID code ("230" for
            // right Option), the way a binding would, so the events the app
            // posts can be watched from outside without a controller.
            // Move the pointer by "dx,dy" pixels through the same path a stick
            // binding uses, or click "0" / "1" where it is, so the coordinate
            // flip can be checked from outside without a controller.
            .onReceive(dnc("inputconfig.debug.mouse")) { note in
                let parts = ((note.object as? String) ?? "").split(separator: ",").compactMap { Int($0) }
                guard parts.count == 2 else { return }
                InputSimulator.shared.moveMouse(deltaX: parts[0], deltaY: parts[1])
            }
            .onReceive(dnc("inputconfig.debug.help")) { note in
                let id = (note.object as? String) ?? "home"
                HelpGuideWindowController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NotificationCenter.default.post(name: Notification.Name("inputconfig.debug.helpSelect"), object: id)
                }
            }
            .onReceive(dnc("inputconfig.debug.legacyalert")) { note in
                let kind = (note.object as? String) ?? ""
                DispatchQueue.main.async { LegacyRowCheck.shared.debugPreview(kind) }
            }
            .onReceive(dnc("inputconfig.debug.fakedevices")) { note in
                HIDDeviceRegistry.shared.debugSetFake((note.object as? String) ?? "")
            }
            .onReceive(dnc("inputconfig.debug.click")) { note in
                let button = Int((note.object as? String) ?? "") ?? 0
                InputSimulator.shared.mouseButtonDown(button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { InputSimulator.shared.mouseButtonUp(button) }
            }
            .onReceive(dnc("inputconfig.debug.key")) { note in
                guard let code = Int((note.object as? String) ?? "") else { return }
                InputSimulator.shared.keyDown(code)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { InputSimulator.shared.keyUp(code) }
            }
            .onReceive(dnc("inputconfig.debug.tipjar")) { _ in
                TipJarWindowController.shared.show()
            }
            .onReceive(dnc("inputconfig.debug.testbench")) { _ in
                // The whole test bench, headless: counts and every failure
                // to testbench.txt, for a check from the shell.
                // A start line goes first, so a run that hangs leaves this
                // run's line rather than the last run's counts.
                guard !TestBenchService.shared.isRunning else { return }
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("testbench.txt")
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                try? "running build \(build) since \(Date())\n".write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    _ = await TestBenchService.shared.runAll()
                    // A finished line, not one a hung run's start line matches.
                    let text = TestBenchService.shared.headlessReport + "finished build \(build)\n"
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            // `post inputconfig.debug.pageprobe [WxH]`: the page build probe
            // (PageBuildProbe) in an offscreen window, by default at the size
            // of the page in the main window. Writes tmp/pageprobe.txt.
            .onReceive(dnc("inputconfig.debug.pageprobe")) { note in
                guard let engine = AppState.current?.mappingEngine else { return }
                var size = CGSize(width: 900, height: 760)
                let parts = ((note.object as? String) ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 {
                    size = CGSize(width: parts[0], height: parts[1])
                } else if let content = MenuBarController.mainWindow?.contentView?.frame.size {
                    // Less the sidebar, about its default width.
                    size = CGSize(width: max(500, content.width - 280), height: content.height)
                }
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pageprobe.txt")
                try? "running since \(Date())\n".write(to: url, atomically: true, encoding: .utf8)
                let store = presetStore, controllers = controllerService
                Task { @MainActor in
                    let text = await PageBuildProbe.run(store: store, engine: engine, controllers: controllers, size: size)
                    try? (text + "\nfinished\n").write(to: url, atomically: true, encoding: .utf8)
                }
            }
            // `post inputconfig.debug.selectid <uuid>`: select by id. The name
            // form picks the first of two presets with the same name.
            .onReceive(dnc("inputconfig.debug.selectid")) { note in
                if let s = note.object as? String, let id = UUID(uuidString: s),
                   presetStore.presets.contains(where: { $0.id == id }) {
                    editingPreset = nil
                    selectedPresetId = id
                }
            }
            // `post inputconfig.debug.perfbench "all runs=5 pad"`: the
            // performance cases (TestBenchService.runPerformance) to
            // perfbench.txt, a running line first and a finished line last,
            // as testbench.txt. Cases: switch tick save launch keystroke viz
            // memory, or all.
            .onReceive(dnc("inputconfig.debug.perfbench")) { note in
                guard !TestBenchService.shared.isRunning else { return }
                var options = PerfOptions()
                var names: Set<String> = []
                for word in ((note.object as? String) ?? "all").split(separator: " ").map(String.init) {
                    if word == "pad" { options.pad = true }
                    else if word.hasPrefix("runs="), let n = Int(word.dropFirst(5)) { options.runs = max(2, min(9, n)) }
                    else { names.insert(word) }
                }
                if !names.isEmpty { options.cases = names }
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("perfbench.txt")
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                try? "running build \(build) since \(Date())\n".write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    await TestBenchService.shared.runPerformance(options)
                    let text = TestBenchService.shared.perfReport + "finished build \(build)\n"
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            .onReceive(dnc("inputconfig.debug.pointerprobe")) { note in
                Task { @MainActor in
                    let report = await PointerSpeedShaper.runProbe(shapingAt: Double((note.object as? String) ?? "") ?? 1)
                    try? report.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pointerprobe.txt"),
                                      atomically: true, encoding: .utf8)
                }
            }
            .onReceive(dnc("inputconfig.debug.pointertest")) { _ in
                Task { @MainActor in
                    let report = await PointerSpeedShaper.runLiveTest()
                    try? report.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pointertest.txt"),
                                      atomically: true, encoding: .utf8)
                }
            }
            // `post inputconfig.debug.restorebuiltins`: Settings' Restore
            // Built-in Presets, for a built-in moved out of the library.
            .onReceive(dnc("inputconfig.debug.restorebuiltins")) { _ in
                _ = presetStore.restoreBuiltInPresets()
            }
            // `post inputconfig.debug.voicestate`: the voice listener's state
            // and what it heard, to tmp/voicestate.txt.
            .onReceive(dnc("inputconfig.debug.voicestate")) { _ in
                let v = VoicePhraseService.shared
                let now = ProcessInfo.processInfo.systemUptime
                let heard = v.phrases.map { p in "\(p.phrase): heard \(v.lastHeard[p.id].map { String(format: "%.1f s ago", now - $0) } ?? "never")" }
                let log = ActivityLog.shared.entries.suffix(25).map { "\($0.time) [\($0.source)] \($0.text)" }
                let text = "listening=\(v.listening) tracking=\(v.isTracking)\n\(v.debugDirectStats)\nproblem=\(v.problem ?? "none")\ntranscript=\(v.transcript)\n"
                    + heard.joined(separator: "\n") + "\n--- log\n" + log.joined(separator: "\n") + "\n"
                try? text.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("voicestate.txt"), atomically: true, encoding: .utf8)
            }
            .onReceive(dnc("inputconfig.debug.enginestate")) { _ in
                let running = MenuBarController.shared.debugEngineRunning
                let active = MenuBarController.shared.debugActivePresetName ?? "none"
                let held = InputSimulator.shared.debugHeldKeyCount
                let report = DebugStateReport.text(service: controllerService, running: running,
                                                   active: active, held: held)
                    + DebugReplay.stateText(service: controllerService)
                try? report.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("enginestate.txt"),
                                  atomically: true, encoding: .utf8)
            }
            // `post inputconfig.debug.replay "<fixture-id> [slot]" | "seq:<id>"
            // | "file:/path [vid:pid]" | "off"`: fixture bytes through the
            // live pipeline on synthetic pads (see DebugReplay).
            .onReceive(dnc("inputconfig.debug.replay")) { note in
                DebugReplay.shared.handle((note.object as? String) ?? "")
            }
            // `post inputconfig.debug.eventlog start|stop`: every CGEvent the
            // engine would post goes to tmp/eventlog.txt instead of the Mac.
            .onReceive(dnc("inputconfig.debug.eventlog")) { note in
                DebugReplay.shared.eventLog((note.object as? String) ?? "start")
            }
            // `post inputconfig.debug.hidcapture "<vid:pid|all> [seconds]"`:
            // HID traffic for that device to tmp/hidcapture.txt.
            .onReceive(dnc("inputconfig.debug.hidcapture")) { note in
                DebugReplay.shared.hidCapture((note.object as? String) ?? "all")
            }
            .onReceive(dnc("inputconfig.debug.capture")) { note in
                // In-process render of the frontmost sheet or window for
                // layout checks; "<name>-full" renders the whole scrolled
                // document. Needs no screen-recording grant.
                let name = (note.object as? String) ?? "icapture"
                // Last fallback: the main window even when another app is in
                // front (or Stage Manager has it parked), so a capture never
                // needs the app focused.
                // The deepest sheet: a sheet opened from the editor sits on
                // the editor's own sheet.
                var top = NSApp.windows.first { $0.isVisible && $0.attachedSheet != nil }?.attachedSheet
                while let next = top?.attachedSheet { top = next }
                let win = top
                    ?? NSApp.keyWindow ?? NSApp.mainWindow
                    ?? NSApp.windows.first { $0.canBecomeMain && $0.contentView != nil && $0.frame.width > 400 }
                var target = win?.contentView
                // "<name>-popover" renders an open popover instead.
                if name.hasSuffix("-popover"),
                   let pop = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
                    target = pop.contentView?.superview ?? pop.contentView
                }
                if name.hasSuffix("-full"), let root = target {
                    func scrolls(_ v: NSView) -> [NSScrollView] {
                        (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrolls)
                    }
                    if let doc = scrolls(root).max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })?.documentView {
                        target = doc
                    }
                }
                guard let view = target,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        #else
        content
        #endif
    }

    #if DEBUG
    private func dnc(_ name: String) -> NotificationCenter.Publisher {
        // Distributed notifications are held back for an app that is not in
        // front unless the observer asks for immediate delivery, which the
        // Combine publisher cannot. The relay registers each hook name once
        // with `.deliverImmediately` and re-posts it in-process, so the
        // hooks keep working while another app is frontmost.
        DebugHookRelay.shared.ensure(name)
        return NotificationCenter.default.publisher(for: Notification.Name(name))
    }
    private func preset(_ note: Notification) -> Preset? {
        (note.object as? String).flatMap { n in
            presetStore.presets.first(where: { $0.name == n })
        }
    }
    private func selected() -> Preset? {
        selectedPresetId.flatMap { id in presetStore.presets.first(where: { $0.id == id }) }
    }
    private func closeSheets() {
        editingPreset = nil
        showingSmartMaker = false
        showingStats = false
        settingsSheetTab = nil
        showingMotion = false
        showingTouchpad = false
        presentedDemoKind = nil
    }
    #endif
}

// MARK: - Debug marketing state (drives sub-views into capture-ready states)

#if DEBUG
/// A tiny shared, DEBUG-only observable that the marketing capture pipeline
/// toggles via DistributedNotificationCenter to put deep sub-views (the
/// binding editor's advanced options, the visualizer's edit-layout mode, the
/// One-Stick Driving arena) into a screenshot-ready state without clicking.
import Combine
@MainActor
final class DebugMarketing: ObservableObject {
    static let shared = DebugMarketing()
    @Published var expandOptions = false
    @Published var editLayout = false
    @Published var oneStick = false
    @Published var fakeController = false
    /// Each post of inputconfig.debug.fakeswap swaps the synthetic pads' slots.
    @Published var fakeSwaps = 0
    /// `post inputconfig.debug.fakeset "dualsense,xbox"`: that synthetic set,
    /// one controller per slot; an empty string removes them.
    @Published var fakeSet: [String]?
    @Published var fakePress = false
    @Published var noFree = false
    @Published var vizScale: Double?
    /// `post inputconfig.debug.cursorregions <fraction>`: the screen map
    /// draws each corner region grown to that fraction of the screen, from
    /// its own corner, so a marketing capture shows them large. Drawing only:
    /// the preset and the live regions are unchanged. 0 turns it off.
    @Published var cursorRegionSize: Double?
    private init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("inputconfig.debug.cursorregions"), object: nil, queue: .main) { [weak self] note in
            let v = (note.object as? String).flatMap(Double.init) ?? 0
            self?.cursorRegionSize = v > 0 ? min(0.45, v) : nil
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakecontroller"), object: nil, queue: .main) { [weak self] _ in
            self?.fakeController.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakeset"), object: nil, queue: .main) { [weak self] note in
            let kinds = ((note.object as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self?.fakeSet = kinds
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakeswap"), object: nil, queue: .main) { [weak self] _ in
            self?.fakeSwaps += 1
        }
        dnc.addObserver(forName: .init("inputconfig.debug.zoom"), object: nil, queue: .main) { [weak self] note in
            if let v = (note.object as? String).flatMap(Double.init) { self?.vizScale = v }
        }
        dnc.addObserver(forName: .init("inputconfig.debug.expandOptions"), object: nil, queue: .main) { [weak self] _ in
            self?.expandOptions.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.editLayout"), object: nil, queue: .main) { [weak self] _ in
            self?.editLayout.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.oneStick"), object: nil, queue: .main) { [weak self] _ in
            self?.oneStick.toggle()
        }
        // Live-usage pictures for the Mac-input visualizers:
        //   fakeext "<spec>"   light keys / mouse inputs for 8 s (see debugMark)
        //   swipe              start or stop a synthetic finger swipe on the pad
        //   pointer "fx fy"    warp the real pointer to a fraction of the main display
        dnc.addObserver(forName: .init("inputconfig.debug.fakeext"), object: nil, queue: .main) { note in
            ExternalInputDeviceService.shared.debugMark(spec: (note.object as? String) ?? "", seconds: 8)
        }
        dnc.addObserver(forName: .init("inputconfig.debug.swipe"), object: nil, queue: .main) { _ in
            TouchpadService.shared.debugSwipeStart = TouchpadService.shared.debugSwipeStart == nil ? Date() : nil
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakepress"), object: nil, queue: .main) { [weak self] _ in
            self?.fakePress.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakeaxes"), object: nil, queue: .main) { note in
            // "0:0.2 1:-0.4" fixes those axes; "off" returns to the sweep.
            let spec = (note.object as? String) ?? "off"
            if spec == "off" { GameControllerService.debugFixedAxes = nil; return }
            var fixed: [Int: Float] = [:]
            for part in spec.split(separator: " ") {
                let kv = part.split(separator: ":")
                if kv.count == 2, let k = Int(kv[0]), let v = Float(kv[1]) { fixed[k] = v }
            }
            GameControllerService.debugFixedAxes = fixed
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakeports"), object: nil, queue: .main) { note in
            // "2:trigger 4:stick" plugs those in; empty takes them out.
            var ports: [Int: AccessControllerPortService.PortDevice] = [:]
            for part in ((note.object as? String) ?? "").split(separator: " ") {
                let kv = part.split(separator: ":")
                guard kv.count == 2, let port = Int(kv[0]) else { continue }
                ports[port] = kv[1] == "stick" ? .stick : kv[1] == "trigger" ? .trigger : .button
            }
            GameControllerService.debugAccessPorts = ports
        }
        dnc.addObserver(forName: .init("inputconfig.debug.nofree"), object: nil, queue: .main) { [weak self] _ in
            self?.noFree.toggle()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.accent"), object: nil, queue: .main) { note in
            // "<automatic|blue|cyan|...>": the Settings accent, set in-process.
            let raw = (note.object as? String) ?? AppAccent.automatic.rawValue
            UserDefaults.standard.set(AppAccent(rawValue: raw)?.rawValue ?? AppAccent.automatic.rawValue,
                                      forKey: AppAccent.storageKey)
        }
        dnc.addObserver(forName: .init("inputconfig.debug.faketap"), object: nil, queue: .main) { _ in
            ChassisTapService.shared.debugInjectDoubleTap()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakeheard"), object: nil, queue: .main) { note in
            // The words shown as just heard, or nothing to go back to normal.
            debugVoiceHeardWords = (note.object as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        dnc.addObserver(forName: .init("inputconfig.debug.fakemidi"), object: nil, queue: .main) { _ in
            MIDIInputService.shared.debugToggleFakeInstrument()
        }
        dnc.addObserver(forName: .init("inputconfig.debug.pointer"), object: nil, queue: .main) { note in
            let parts = ((note.object as? String) ?? "").split(separator: " ").compactMap { Double($0) }
            guard parts.count == 2, let screen = NSScreen.screens.first else { return }
            let f = screen.frame
            CGWarpMouseCursorPosition(CGPoint(x: f.origin.x + f.width * parts[0], y: f.height * parts[1]))
        }
    }
}

/// `post inputconfig.debug.replay`: fixture bytes from `HIDFixtureCorpus`
/// through the live pipeline on synthetic pads, so a slot can be driven
/// with no hardware attached. Object string grammar:
///   "<fixture-id> [slot]"      one fixture (slot is informational: the
///                              service assigns it)
///   "seq:<sequence-id>"        the steps at their own delays
///   "file:/path [vid:pid]"     lines "<t_ms> <id hex> <bytes hex>" scheduled
///                              at their offsets on a raw pad for vid:pid (hex)
///   "off"                      remove the synthetic pads, release decoding
/// Refused while the marketing fakes own the slots. Routes that have no
/// live injection point log "not replayable".
@MainActor
final class DebugReplay {
    static let shared = DebugReplay()
    static let accessLocation: UInt64 = 0xFA5E_0000_ACCE_5500
    static let supplementBase: UInt64 = 0xFA5E_0000_D5E0_0000
    nonisolated static let fileLock = NSLock()
    private var rawKeys: [String: UInt64] = [:]
    private var accessInstalled = false
    private var supplementInstalled: Set<Int32> = []
    private var scheduled: [DispatchWorkItem] = []
    private var holdingDecode = false

    private init() {
        // A leaked decode reason keeps real pads decoding at full rate.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DebugReplay.shared.stop() }
        }
    }

    private func log(_ text: String) {
        ActivityLog.shared.info("Replay", text)
    }

    func handle(_ spec: String) {
        let parts = spec.split(separator: " ").map(String.init)
        guard let first = parts.first else {
            log("usage: <fixture-id> [slot] | seq:<id> | file:/path [vid:pid] | off")
            return
        }
        if first == "off" { stop(); log("off"); return }
        let marketing = DebugMarketing.shared
        if (marketing.fakeSet?.isEmpty == false) || marketing.fakeController {
            log("refused: marketing fakes own the slots (fakeset or fakecontroller is on)")
            return
        }
        GameControllerService.debugScriptedStates = [:]
        holdDecode()
        if first.hasPrefix("seq:") {
            playSequence(String(first.dropFirst(4)))
        } else if first.hasPrefix("file:") {
            playFile(String(first.dropFirst(5)), vidpid: parts.dropFirst().first)
        } else {
            playFixture(first, slot: parts.dropFirst().first)
        }
    }

    private func holdDecode() {
        guard !holdingDecode else { return }
        holdingDecode = true
        RawHIDGamepadService.shared.setDecodingWanted(true, reason: "replay")
    }

    func stop() {
        for item in scheduled { item.cancel() }
        scheduled.removeAll()
        RawHIDGamepadService.shared.debugRemoveSyntheticPads()
        rawKeys.removeAll()
        accessInstalled = false
        supplementInstalled.removeAll()
        if holdingDecode {
            holdingDecode = false
            RawHIDGamepadService.shared.setDecodingWanted(false, reason: "replay")
        }
    }

    private func playFixture(_ id: String, slot: String?) {
        guard let fixture = HIDFixtureCorpus.all.first(where: { $0.id == id }) else {
            log("no fixture named \(id)")
            return
        }
        inject(fixture.route, reportID: fixture.reportID, bytes: fixture.bytes,
               device: fixture.device, transport: fixture.transport, id: fixture.id)
        log("\(id): \(fixture.bytes.count) bytes" + (slot.map { ", slot \($0) requested (the service assigns slots)" } ?? ""))
    }

    private func playSequence(_ id: String) {
        guard let seq = HIDFixtureCorpus.sequences.first(where: { $0.id == id }) else {
            log("no sequence named \(id)")
            return
        }
        let transport: HIDFixture.Transport = {
            if case .rawHID(_, _, let t) = seq.route, t?.lowercased().contains("bluetooth") == true { return .bluetooth }
            return .usb
        }()
        var offsetMs = 0
        for (index, step) in seq.steps.enumerated() {
            offsetMs += step.delayMs
            let bytes = HIDFixture.parse(step.hex)
            schedule(afterMs: offsetMs) { [weak self] in
                self?.inject(seq.route, reportID: step.reportID, bytes: bytes,
                             device: seq.id, transport: transport, id: "\(seq.id)#\(index)")
            }
        }
        log("seq:\(id): \(seq.steps.count) steps over \(offsetMs) ms")
    }

    private func playFile(_ path: String, vidpid: String?) {
        guard let ids = Self.parseVidPid(vidpid) else {
            log("file replay needs vid:pid (hex) after the path")
            return
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            log("cannot read \(path)")
            return
        }
        let route = HIDFixture.Route.rawHID(vendorID: ids.vid, productID: ids.pid, transport: nil)
        var count = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let ms = Int(fields[0]), let id = UInt8(fields[1], radix: 16) else { continue }
            let bytes = HIDFixture.parse(fields[2...].joined(separator: " "))
            guard !bytes.isEmpty else { continue }
            count += 1
            let lineNumber = count
            schedule(afterMs: ms) { [weak self] in
                self?.inject(route, reportID: id, bytes: bytes, device: "capture",
                             transport: .usb, id: "file line \(lineNumber)")
            }
        }
        log("file:\(path): \(count) reports scheduled on \(String(format: "%04x:%04x", ids.vid, ids.pid))")
    }

    private func schedule(afterMs ms: Int, _ body: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        scheduled.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000, execute: item)
    }

    static func parseVidPid(_ text: String?) -> (vid: Int32, pid: Int32)? {
        guard let text else { return nil }
        let halves = text.split(separator: ":")
        guard halves.count == 2, let vid = Int32(halves[0], radix: 16), let pid = Int32(halves[1], radix: 16) else { return nil }
        return (vid, pid)
    }

    private func rawKey(vendorID: Int32, productID: Int32, transport: String, name: String, descriptor: [UInt8]?) -> UInt64? {
        let mapKey = "\(vendorID):\(productID)"
        if let key = rawKeys[mapKey] { return key }
        guard let key = RawHIDGamepadService.shared.debugInstallSyntheticPad(
            vendorID: vendorID, productID: productID, transport: transport, productName: name, descriptor: descriptor) else {
            log("could not install a synthetic pad for \(String(format: "%04x:%04x", vendorID, productID))")
            return nil
        }
        rawKeys[mapKey] = key
        return key
    }

    private func inject(_ route: HIDFixture.Route, reportID: UInt8, bytes: [UInt8], device: String,
                        transport: HIDFixture.Transport, id: String) {
        let raw = RawHIDGamepadService.shared
        switch route {
        case .rawHID(let vid, let pid, let t):
            let name = t ?? (transport == .bluetooth ? "Bluetooth" : "USB")
            guard let key = rawKey(vendorID: vid, productID: pid, transport: name, name: device, descriptor: nil) else { return }
            raw.dispatchOnReportThread(key: key, reportID: UInt32(reportID), bytes: bytes)
        case .descriptor(_, let desc, let vid, let pid, _):
            // The fixture's device name, as IOKit would report it; the
            // route's name is a locator for the bench.
            let transportName = transport == .bluetooth ? "Bluetooth" : "USB"
            guard let key = rawKey(vendorID: vid, productID: pid, transport: transportName, name: device, descriptor: desc) else { return }
            raw.dispatchOnReportThread(key: key, reportID: UInt32(reportID), bytes: bytes)
        case .accessPorts:
            if !accessInstalled {
                _ = AccessControllerPortService.shared.debugInstallSyntheticPad(location: Self.accessLocation,
                                                                               overUSB: transport != .bluetooth)
                accessInstalled = true
            }
            AccessControllerPortService.shared.debugInject(location: Self.accessLocation, bytes: bytes)
        case .dualSenseSupplement(let pid):
            let location = Self.supplementBase | UInt64(UInt32(bitPattern: pid))
            if !supplementInstalled.contains(pid) {
                _ = DualSenseSupplementService.shared.debugInstall(location: location, productID: pid)
                supplementInstalled.insert(pid)
            }
            DualSenseSupplementService.shared.debugInject(location: location, bytes: bytes)
        default:
            log("\(id): not replayable (route \(route) has no live injection point)")
        }
    }

    // MARK: - eventlog and hidcapture

    nonisolated static func append(_ line: String, to url: URL) {
        fileLock.lock(); defer { fileLock.unlock() }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// "start" routes every engine CGEvent to tmp/eventlog.txt as
    /// "type keycode flags x,y" lines; "stop" posts to the Mac again.
    func eventLog(_ arg: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eventlog.txt")
        if arg.trimmingCharacters(in: .whitespaces) == "stop" {
            InputSimulator.debugEventSink = nil
            Self.append("# eventlog stop", to: url)
            log("eventlog stopped")
            return
        }
        Self.fileLock.lock(); try? Data().write(to: url); Self.fileLock.unlock()
        Self.append("# eventlog start \(ISO8601DateFormatter().string(from: Date()))", to: url)
        Self.append("# type keycode flags x,y", to: url)
        InputSimulator.debugEventSink = { event in
            let p = event.location
            let line = "\(event.type.rawValue) \(event.getIntegerValueField(.keyboardEventKeycode)) \(event.flags.rawValue) \(Int(p.x)),\(Int(p.y))"
            DebugReplay.append(line, to: url)
        }
        log("eventlog started")
    }

    /// "<vid:pid|all> [seconds]": starts an HIDCapture window (10 s default).
    func hidCapture(_ arg: String) {
        let parts = arg.split(separator: " ").map(String.init)
        let who = parts.first ?? "all"
        let seconds = parts.dropFirst().first.flatMap(Double.init) ?? 10
        if who == "all" {
            HIDCapture.start(vendorID: nil, productID: nil, seconds: seconds)
        } else if let ids = Self.parseVidPid(who) {
            HIDCapture.start(vendorID: ids.vid, productID: ids.pid, seconds: seconds)
        } else {
            log("hidcapture: usage <vid:pid|all> [seconds]")
            return
        }
        log("hidcapture \(who) for \(Int(seconds)) s to \(HIDCapture.url.path)")
    }

    /// Appended to enginestate.txt: every raw pad's decoded state and the
    /// Access single-pad view (empty when nothing is attached or installed).
    static func stateText(service svc: GameControllerService) -> String {
        var out = ""
        for (slot, pad) in svc.rawHIDGamepadSlots.sorted(by: { $0.key < $1.key }) {
            let st = pad.state
            let pressed = st.buttons.filter { $0.value > 0.5 }.keys.sorted()
            let axes = st.axes.sorted { $0.key < $1.key }.map { "a\($0.key)=" + String(format: "%.2f", $0.value) }
            let hats = st.hats.sorted { $0.key < $1.key }.map { "h\($0.key)=\($0.value.x),\($0.value.y)" }
            out += "raw slot \(slot) \(pad.productName) [\(String(format: "%04x:%04x", pad.vendorID, pad.productID))]: pressed \(pressed) axes \(axes.joined(separator: " ")) hats \(hats.joined(separator: " "))\n"
        }
        let access = AccessControllerPortService.shared
        let axes = access.axes(for: nil, accessSlotCount: 1)
        let buttons = access.buttons(for: nil, accessSlotCount: 1)
        let ports = access.portDevices(for: nil, accessSlotCount: 1)
        let active = access.activeProfile(for: nil, accessSlotCount: 1)
        if !axes.isEmpty || !buttons.isEmpty || !ports.isEmpty || active.number != 0 {
            let axisText = axes.sorted { $0.key < $1.key }.map { "a\($0.key)=" + String(format: "%.2f", $0.value) }
            let pressed = buttons.filter { $0.value > 0.5 }.keys.sorted()
            let portText = ports.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            out += "access pad: axes \(axisText.joined(separator: " ")) pressed \(pressed) ports {\(portText.joined(separator: ", "))} activeProfile \(active.number) \(active.profile?.name ?? "")\n"
        }
        return out
    }
}
#endif

extension View {
    /// DEBUG-only: expands this binding row's advanced options when the
    /// marketing pipeline toggles DebugMarketing.expandOptions. No-op in Release.
    @ViewBuilder func debugExpandOptions(_ showAdvanced: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$expandOptions) { if $0 { showAdvanced.wrappedValue = true } }
        #else
        self
        #endif
    }

    /// DEBUG-only: engages the visualizer's Edit Layout mode on toggle.
    @ViewBuilder func debugEditLayout(_ editMode: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$editLayout) { editMode.wrappedValue = $0 }
        #else
        self
        #endif
    }

    /// DEBUG-only: expands and enables the One-Stick Driving section + arena.
    @ViewBuilder func debugOneStick(expanded: Binding<Bool>, enable: Binding<Bool>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$oneStick) {
            if $0 { expanded.wrappedValue = true; enable.wrappedValue = true }
        }
        #else
        self
        #endif
    }

    /// DEBUG-only: injects / removes the two synthetic marketing controllers so
    /// captures show a populated sidebar and visualizer with no hardware.
    @ViewBuilder func debugFakeController(_ service: GameControllerService) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$fakeController) { service.setMarketingFakeControllers($0) }
            .onReceive(DebugMarketing.shared.$fakeSwaps.dropFirst()) { _ in service.swapMarketingFakeControllers() }
            .onReceive(DebugMarketing.shared.$fakeSet.compactMap { $0 }) { service.setMarketingFakeSet($0) }
        .onReceive(DebugMarketing.shared.$fakePress) { service.marketingFakePress = $0 }
        #else
        self
        #endif
    }

    /// DEBUG-only: sets the live visualizer's zoom for marketing captures.
    @ViewBuilder func debugVizZoom(_ scale: Binding<Double>) -> some View {
        #if DEBUG
        onReceive(DebugMarketing.shared.$vizScale) { if let v = $0 { scale.wrappedValue = v } }
        #else
        self
        #endif
    }

    /// DEBUG-only: presents the deadzone-calibration and one-stick-driving
    /// views as standalone sheets for marketing capture. No-op in Release.
    @ViewBuilder func debugCaptureSheets() -> some View {
        #if DEBUG
        modifier(DebugCaptureSheets())
        #else
        self
        #endif
    }
}

#if DEBUG
/// DEBUG-only: drives the deadzone calibrator (joystick axis 0, trigger axis 4)
/// and the One-Stick Driving arena into standalone sheets via distributed
/// notifications, so marketing captures don't depend on fragile clicks.
///   inputconfig.debug.deadzone <axisIndex>   0/2 = stick, 4/5 = trigger
///   inputconfig.debug.drive                  one-stick driving arena
struct DebugCaptureSheets: ViewModifier {
    @State private var deadzoneAxis: Int?
    @State private var dz: Double = 0.18
    @State private var odz: Double = 0.9
    @State private var showDrive = false
    @State private var showScreenRegions = false
    @State private var showStickZones = false
    @State private var driveCfg: DriveConfig? = {
        var c = DriveConfig(); c.enabled = true; return c
    }()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { deadzoneAxis != nil },
                                        set: { if !$0 { deadzoneAxis = nil } })) {
                if let ax = deadzoneAxis {
                    // Present exactly as the shipping path in BindingRowView does:
                    // no forced frame, so the sheet hugs its content. A
                    // minHeight here padded the sheet ~100pt taller than the
                    // content and every captured screenshot showed dead space
                    // that does not exist in the real app.
                    DeadzoneCalibrationView(axisIndex: ax, deadzone: $dz, outerDeadzone: $odz,
                                            isInverted: false, onClose: { deadzoneAxis = nil })
                        .glassBackground()
                }
            }
            .sheet(isPresented: $showScreenRegions) {
                CursorRegionsView().glassBackground()
            }
            .onReceive({ () -> NotificationCenter.Publisher in
                DebugHookRelay.shared.ensure("inputconfig.debug.screenregions")
                return NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.screenregions"))
            }()) { _ in showScreenRegions = true }
            // inputconfig.debug.stickzones [0|1|2|ring]: the stick zones sheet
            // on the left or right stick, the trigger and axis bands, or the
            // left stick set to draw rings. Its zones live only in memory.
            .sheet(isPresented: $showStickZones) {
                StickRegionsView().glassBackground()
            }
            .onReceive({ () -> NotificationCenter.Publisher in
                DebugHookRelay.shared.ensure("inputconfig.debug.stickzones")
                return NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.stickzones"))
            }()) { note in
                StickRegionsView.debugStart = note.object as? String
                showStickZones = true
            }
            .sheet(isPresented: $showDrive) {
                // A ScrollView has no intrinsic height, so this one genuinely
                // needs a minHeight; without it the sheet collapses to a
                // sliver. Only the deadzone sheet was wrongly forced taller
                // than its content.
                ScrollView { DriveModeSection(driveConfig: $driveCfg).padding(28) }
                    .frame(minWidth: 760, minHeight: 720)
                    // Marketing capture only: suppress the macOS keyboard focus
                    // ring the sheet auto-draws on the disclosure control, which
                    // showed up as a stray bordered box over the section title.
                    .focusEffectDisabled()
                    .glassBackground()
            }
            // The close hook reaches these sheets too; they live here, not
            // on ContentView, so its closeSheets could not drop them.
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.closesheets"))) { _ in
                deadzoneAxis = nil
                showDrive = false
                showScreenRegions = false
                showStickZones = false
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.deadzone"))) { note in
                deadzoneAxis = (note.object as? String).flatMap { Int($0) } ?? 0
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("inputconfig.debug.drive"))) { _ in
                showDrive = true
            }
    }
}
#endif

#if DEBUG
// MARK: - Editor row bench

/// DEBUG: builds editor rows offscreen, the way the editor lays them out
/// (closed, numbered, with Duplicate and Move), and reports what each row
/// costs, so a change to the row can be measured before and after; and
/// collects every string a closed row hands to VoiceOver and Voice Control
/// for every shipped preset, so the change can be shown to keep them.
@MainActor
enum EditorRowBench {
    struct Cost {
        let rows: Int
        let footprintKB: Double
        let heapKB: Double
        let views: Double
        let layers: Double
        let buildMs: Double
        let residualKB: Double
        var line: String {
            String(format: "%d rows: footprint %.0f KB/row, heap %.0f KB/row, %.1f AppKit views/row, %.1f layers/row, build %.1f ms/row, kept after teardown %.0f KB/row",
                   rows, footprintKB, heapKB, views, layers, buildMs, residualKB)
        }
    }

    @MainActor
    final class Rows {
        var rows: [BindingModel]
        init(_ rows: [BindingModel]) { self.rows = rows }
    }

    struct RowList: View {
        let box: Rows
        let family: FaceLetters?
        var body: some View {
            VStack(spacing: 6) {
                ForEach(box.rows.indices, id: \.self) { i in
                    BindingRowView(binding: SwiftUI.Binding(get: { box.rows[i] }, set: { box.rows[i] = $0 }),
                                   onScan: {}, onRemove: {}, onDuplicate: {}, onMove: { _ in },
                                   displayNumber: i + 1)
                }
            }
            .padding(12)
            .frame(width: 1180)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.presetButtonFamily, family)
            .modifier(AccessibilityAdjustments())
        }
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    private static func count(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + count($1) } }
    private static func count(_ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return 1 + (layer.sublayers ?? []).reduce(0) { $0 + count($1) }
    }

    /// Hosts the rows in a borderless window placed far off every screen
    /// (never key, never seen), so layers and their backing are made as in
    /// the editor.
    private static func host(_ rows: [BindingModel], family: FaceLetters?) -> (NSWindow, NSView) {
        var root = AnyView(RowList(box: Rows(rows), family: family))
        if let app = AppState.current {
            root = AnyView(root.environmentObject(app.controllerService).environmentObject(app.presetStore)
                .environmentObject(app.mappingEngine))
        }
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -40000, y: -40000, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        return (window, view)
    }

    private static func settle(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Builds `rows` once and measures it. The rows get fresh ids, so the
    /// same row can be repeated.
    static func cost(of rows: [BindingModel], family: FaceLetters? = nil) async -> Cost {
        let rows = rows.map { $0.duplicated() }
        await settle(300)
        let f0 = footprint(), h0 = heapInUse()
        let start = Date()
        let (window, view) = host(rows, family: family)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let buildMs = Date().timeIntervalSince(start) * 1000
        await settle(500)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let f1 = footprint(), h1 = heapInUse()
        let views = count(view), layers = count(view.layer)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        await settle(500)
        let f2 = footprint()
        let n = Double(max(1, rows.count))
        return Cost(rows: rows.count,
                    footprintKB: Double(f1 - f0) / 1024 / n,
                    heapKB: Double(h1 - h0) / 1024 / n,
                    views: Double(views) / n,
                    layers: Double(layers) / n,
                    buildMs: buildMs / n,
                    residualKB: Double(f2 - f0) / 1024 / n)
    }

    /// Every shipped preset's rows, rendered closed: the strings each row
    /// gives VoiceOver and Voice Control, one line each, in row order.
    static func accessibilityDump() async -> (lines: [String], rows: Int) {
        var lines: [String] = []
        var total = 0
        for preset in ExamplePresets.all {
            let rows = preset.joysticks.flatMap(\.bindings)
            guard !rows.isEmpty else { continue }
            RowA11yProbe.sink = [:]
            let (window, view) = host(rows, family: preset.buttonFamily)
            view.layoutSubtreeIfNeeded()
            await settle(30)
            view.layoutSubtreeIfNeeded()
            let seen = RowA11yProbe.sink ?? [:]
            RowA11yProbe.sink = nil
            window.contentView = nil
            window.close()
            for (number, row) in rows.enumerated() {
                total += 1
                guard let values = seen[row.id] else {
                    lines.append("\(preset.name) #\(number + 1) NOT RENDERED")
                    continue
                }
                for key in values.keys.sorted() {
                    lines.append("\(preset.name) #\(number + 1) \(key)=\(values[key] ?? "")")
                }
            }
        }
        return (lines, total)
    }

    /// FNV-1a, 64 bit: a digest that is the same in every run and build.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
}
#endif
