import AppKit
import Combine
import SwiftUI

/// AppKit-backed menu bar status item. Replaces SwiftUI's MenuBarExtra,
/// which couldn't be hidden at runtime without triggering an infinite
/// scenesDidChange loop on macOS 26. The status item opens a SwiftUI
/// frosted popover styled after YapToText's menu bar surface, carrying
/// EVERY feature the classic NSMenu had: active-session header with tag +
/// binding summary, engine + CPU/RAM status, connected controllers with
/// battery, the grouped preset library, and all app actions.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {

    static let shared = MenuBarController()

    static let defaultsKey = "InputConfig.showMenuBarIcon"
    /// Posted when the user asks for the release notes from the menu bar.
    static let showWhatsNewNotification = Notification.Name("InputConfig.ShowWhatsNew")

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var presetStore: PresetStore?
    private weak var mappingEngine: MappingEngine?
    private weak var controllerService: GameControllerService?
    private var cancellables: Set<AnyCancellable> = []
    /// Watches the menu bar's light/dark appearance so the running (green)
    /// glyph can switch shades the way template menu bar icons auto-invert.
    private var appearanceObservation: NSKeyValueObservation?

    private override init() {
        super.init()
    }

    /// Open the main window (the notes live in a sheet on it) and ask for
    /// the release notes. Gives the popup a permanent home instead of it
    /// being a one-shot that can never be seen again once dismissed.
    func showWhatsNew() {
        Self.pendingMainAction = .whatsNew
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: Self.showWhatsNewNotification, object: nil)
        }
    }

    #if DEBUG
    var debugEngineRunning: Bool { mappingEngine?.isRunning ?? false }
    var debugActivePresetName: String? {
        presetStore?.presets.first(where: { $0.isActive })?.name
    }
    #endif

    /// Wire the kill switch and the per-preset chords. Lives here rather
    /// than in a view because it has to work with every window closed.
    private func installEmergencyStopHandling(presetStore: PresetStore,
                                              mappingEngine: MappingEngine) {
        NotificationCenter.default.addObserver(
            forName: EmergencyStopService.stoppedNotification,
            object: nil, queue: .main
        ) { [weak mappingEngine, weak presetStore] note in
            let byController = (note.userInfo?["reason"] as? String) == EmergencyStopService.Reason.controllerHold.rawValue
            MainActor.assumeIsolated {
                // Only a stop that stopped something arms the restart: one
                // tried with nothing running started yesterday's preset.
                let wasRunning = mappingEngine?.isRunning == true || presetStore?.activePresetId != nil
                EmergencyStopService.shared.lastStopStoppedSomething = wasRunning
                let last = presetStore?.activePresetId ?? presetStore?.lastActivatedPresetId
                // Stop the engine before EmergencyStopService releases the
                // held keys, so nothing is re-pressed on the next frame.
                mappingEngine?.stop()
                presetStore?.deactivateAll()
                // An open editor with nothing changed closes, so a stop from
                // the controller never leaves its user shut in the sheet.
                if byController, let editor = OpenEditor.current {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    if !editor.isDirty() { editor.close() }
                }
                // The same hold starts it again, for someone whose only
                // input is the controller: after any stop, since a stop row
                // or the menu bar clicked with the controller's pointer
                // leaves that person just as stuck.
                guard wasRunning, EmergencyStopService.shared.controllerHoldEnabled, let last, let engine = mappingEngine else { return }
                engine.watchForRestartHold { [weak presetStore, weak engine] in
                    guard let store = presetStore, let engine,
                          let preset = store.presets.first(where: { $0.id == last }) else { return }
                    MenuBarController.activate(preset, store: store, engine: engine, background: true)
                    // Refused (its rows gone, or an import not yet confirmed):
                    // nothing started, so nothing says it did.
                    guard engine.isRunning, store.activePresetId == preset.id else {
                        ActivityLog.shared.warning("Emergency stop", "\(preset.name) could not be started again from the controller hold")
                        return
                    }
                    ActivityLog.shared.info("Emergency stop", "Started \(preset.name) again from the controller hold")
                    // A pad that cannot buzz still hears and sees it start.
                    let said = String(localized: "Started \(preset.shownName)")
                    NSSound(named: "Tink")?.play()
                    AccessibilityNotification.Announcement(said).post()
                    StatusHUD.shared.show(said, seconds: 3)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: PresetHotKeyService.activateNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            MainActor.assumeIsolated { self?.handlePresetHotKey(id) }
        }

        // Keep the registered chords in step with the library.
        presetStore.$presets
            .receive(on: DispatchQueue.main)
            .sink { presets in PresetHotKeyService.shared.sync(with: presets) }
            .store(in: &cancellables)
    }

    /// A preset's own chord: switch to it, or stop it if it is already the
    /// running one.
    private func handlePresetHotKey(_ id: UUID) {
        guard let store = presetStore, let engine = mappingEngine,
              let preset = store.presets.first(where: { $0.id == id }) else { return }
        if store.activePresetId == id {
            engine.stop()
            store.deactivateAll()
            return
        }
        guard preset.isRunnable else { return }
        Self.activate(preset, store: store, engine: engine, background: true)
    }

    /// Every activation outside the main window goes through here: the
    /// menu bar, the hotkeys, auto-switch, and crash restore. They skipped
    /// the Accessibility check, so the popover said "running" while every
    /// key and click the preset sent was dropped.
    /// `background`: started by something other than the person at the Mac
    /// (auto-switch, a controller button). Those never raise the alert,
    /// which pulled focus away from the game in front.
    /// `quietPointerWarning`: the global shortcut, pressed by the person
    /// but often over a game, logs the pointer warning instead of an alert.
    static func activate(_ preset: Preset, store: PresetStore, engine: MappingEngine, background: Bool = false,
                         quietPointerWarning: Bool = false) {
        // A preset with no rows cannot run: it was marked running while
        // the engine refused it.
        guard preset.isRunnable else { return }
        guard store.confirmFirstStart(preset, background: background),
              store.confirmRestrictiveStart(preset, background: background || quietPointerWarning) else { return }
        engine.stop()
        store.activatePreset(preset)
        engine.start(with: preset)
        warnIfAccessibilityMissing(for: preset, background: background)
    }

    private static var warnedAboutAccessibility = false

    /// Say so when a preset needs Accessibility and it is off: in the
    /// activity log always, and once a session in an alert, which works
    /// with no window open.
    static func warnIfAccessibilityMissing(for preset: Preset, background: Bool = false) {
        let permission = AccessibilityPermissionService.shared
        permission.refresh()
        guard preset.needsAccessibility, !permission.isTrusted else { return }
        ActivityLog.shared.warning("Permissions", "\(preset.name) is running but Accessibility is off, so its keys and clicks cannot reach other apps")
        // The menu bar icon turns orange and its menu says why; a modal
        // alert here would cover the game that just came to the front.
        guard !background, !warnedAboutAccessibility else { return }
        warnedAboutAccessibility = true
        let alert = NSAlert()
        alert.messageText = String(localized: "Turn On Accessibility")
        alert.informativeText = String(localized: "\(preset.shownName) is running, but macOS will not deliver its keys and clicks until InputConfig is on in System Settings, Privacy & Security, Accessibility.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { permission.requestAccess() }
    }

    /// Create the status item and seed visibility from defaults. Called once
    /// from app startup with live references to the stores the popover reads.
    #if DEBUG
    /// Tests only: what install does for app actions and the emergency stop,
    /// with no menu bar item, popover or window.
    func debugAttach(presetStore: PresetStore, mappingEngine: MappingEngine, controllerService: GameControllerService?) {
        self.presetStore = presetStore
        self.mappingEngine = mappingEngine
        self.controllerService = controllerService
        installEmergencyStopHandling(presetStore: presetStore, mappingEngine: mappingEngine)
    }
    #endif

    func install(presetStore: PresetStore, mappingEngine: MappingEngine,
                 controllerService: GameControllerService? = nil) {
        guard statusItem == nil else { return }
        self.presetStore = presetStore
        self.mappingEngine = mappingEngine
        self.controllerService = controllerService

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            // Rebuild the glyph whenever the menu bar flips light/dark (a
            // light wallpaper or Light Mode makes the bar light) so the green
            // running-state icon deepens on a light bar the way template
            // menu bar icons auto-invert.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                self?.refreshMenuBarImage()
            }
        }
        statusItem = item
        refreshMenuBarImage()
        installEmergencyStopHandling(presetStore: presetStore, mappingEngine: mappingEngine)
        // Redrawn when Differentiate Without Color changes (its play mark).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshMenuBarImage() } }
        EmergencyStopService.connectedFamily = { [weak mappingEngine] in
            guard let service = mappingEngine?.controllerServiceForSettings else { return nil }
            return service.controllerDetails.keys.sorted().lazy.compactMap { service.namingFamily(forSlot: $0) }.first
        }
        EmergencyStopService.connectedModel = { [weak mappingEngine] in
            guard let service = mappingEngine?.controllerServiceForSettings,
                  let slot = service.controllerDetails.keys.sorted().first(where: { service.namingFamily(forSlot: $0) != nil })
            else { return .none }
            return service.modelNames(forSlot: slot)
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        popover = pop

        let visible = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
        item.isVisible = visible

        // Live cue: the glyph is a normal template icon while idle (adaptive
        // to the menu bar's light/dark) and swaps to a solid green glyph while
        // a preset is running. A green *template tint* rendered black on some
        // menu bars, so we bake a real green, non-template image instead.
        mappingEngine.$isRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuBarImage()
            }
            .store(in: &cancellables)

        // Accessibility turned off while a preset runs (the permission
        // service checks every 10 s then): the glyph turns orange, so the
        // outputs going nowhere show without opening anything.
        AccessibilityPermissionService.shared.$isTrusted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuBarImage()
            }
            .store(in: &cancellables)

        // The running preset was saved with no rows and the engine stopped:
        // show it stopped too, not still running with nothing behind it.
        NotificationCenter.default.publisher(for: MappingEngine.stoppedEmptyPresetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak presetStore] note in
                guard let store = presetStore, let id = note.object as? UUID,
                      store.activePresetId == id else { return }
                store.deactivateAll()
            }
            .store(in: &cancellables)

        // The running preset left the library (its folder was deleted, it
        // went to the trash, a restore replaced it): stop the engine. Only
        // the single-preset delete stopped it before, so deleting a folder
        // that held the running preset left it sending keys and clicks
        // with nothing shown as active.
        presetStore.$presets
            .receive(on: DispatchQueue.main)
            .sink { [weak mappingEngine] presets in
                guard let engine = mappingEngine, engine.isRunning,
                      let running = engine.activePreset?.id,
                      !presets.contains(where: { $0.id == running }) else { return }
                ActivityLog.shared.info("Engine", "Stopped: the running preset was removed")
                engine.stop()
            }
            .store(in: &cancellables)

        // Keep the global hotkey working when the main window is closed.
        // ContentView owns the toggle while a main-capable window exists
        // (its path applies calibration gating); with every window closed,
        // nothing received the notification and the Settings promise
        // ("works anywhere, even while another app is in front") broke in
        // exactly the headless scenario it exists for.
        NotificationCenter.default.publisher(for: GlobalHotKeyService.toggleNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let presetStore = self.presetStore,
                      let mappingEngine = self.mappingEngine else { return }
                // The main window handles the shortcut itself when it is
                // open (it hears it first); this one acts only on a press
                // nobody claimed, which covers a closed window.
                guard GlobalHotKeyService.claim(note) else { return }
                if presetStore.presets.contains(where: { $0.isActive }) {
                    mappingEngine.stop()
                    presetStore.deactivateAll()
                } else {
                    let target = presetStore.lastActivatedPresetId
                        .flatMap { id in presetStore.presets.first(where: { $0.id == id && $0.isRunnable }) }
                        ?? presetStore.presets.first(where: { $0.isRunnable })
                    // From a run loop block: activate can show the
                    // Accessibility alert, and modal inside a main-queue
                    // block held the queue (no Emergency Stop chord).
                    if let target {
                        RunLoop.main.perform(inModes: [.default]) {
                            MainActor.assumeIsolated {
                                Self.activate(target, store: presetStore, engine: mappingEngine, quietPointerWarning: true)
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)

        #if DEBUG
        // Marketing / QA: open (or close) the popover from the shell so its
        // real translucent panel can be captured. DEBUG-only.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("inputconfig.debug.menubar"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.debugTogglePopover()
        }
        #endif
    }

    #if DEBUG
    /// Open/close the menu bar popover anchored to the status item, without a
    /// real click. Used by the marketing capture pipeline.
    private func debugTogglePopover() {
        guard let button = statusItem?.button else { return }
        togglePopover(button)
    }
    #endif

    /// Rebuild the status item glyph for the current running state AND the
    /// current menu bar appearance. Call whenever either changes.
    func refreshMenuBarImage() {
        guard let button = statusItem?.button else { return }
        let running = mappingEngine?.isRunning ?? false
        let blocked = running && accessibilityBlocksRunningPreset
        button.image = Self.makeMenuBarImage(running: running,
                                             blocked: blocked,
                                             appearance: button.effectiveAppearance)
        // The state in words on hover, not only in the icon's color.
        button.toolTip = button.image?.accessibilityDescription
    }

    /// True while the running preset sends keys or clicks and Accessibility
    /// is off, so macOS drops them.
    private var accessibilityBlocksRunningPreset: Bool {
        guard !AccessibilityPermissionService.shared.isTrusted,
              let active = presetStore?.presets.first(where: { $0.isActive }) else { return false }
        return active.needsAccessibility
    }

    /// The glyph the user picked in Settings ▸ General ▸ Dock & Menu Bar.
    static var iconChoice: MenuBarIconChoice {
        MenuBarIconChoice(rawValue: UserDefaults.standard.string(forKey: MenuBarIconChoice.storageKey) ?? "")
            ?? .controller
    }

    /// The base artwork for the chosen icon, sized for the menu bar.
    private static func baseImage(for choice: MenuBarIconChoice) -> (image: NSImage, size: NSSize)? {
        if choice == .controller {
            guard let base = NSImage(named: "ControllerGlyph") else { return nil }
            return (base, NSSize(width: 26, height: 17.4))
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        // Symbols vary in aspect; keep the height the bar expects and let
        // the width follow.
        let h: CGFloat = 17.4
        let w = max(h, symbol.size.width * h / max(1, symbol.size.height))
        return (symbol, NSSize(width: w.rounded(), height: h))
    }

    /// The menu bar glyph (the app's own controller artwork). Idle: template
    /// (system tints it for the menu bar). Running: a solid green,
    /// non-template copy so "mappings on" reads at a glance. Because a colored
    /// (non-template) image does not auto-invert, the green shade is chosen
    /// from the menu bar's light/dark appearance: a bright system green on a
    /// dark bar, a deeper forest green on a light bar, so it stays legible
    /// either way, like the way macOS menu bar icons adapt.
    private static func makeMenuBarImage(running: Bool,
                                         blocked: Bool = false,
                                         appearance: NSAppearance) -> NSImage? {
        guard let (base, size) = baseImage(for: iconChoice) else { return nil }
        if running {
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let fill: NSColor = blocked
                ? (isDark ? NSColor.systemOrange : NSColor(srgbRed: 0.72, green: 0.36, blue: 0.0, alpha: 1.0))
                : isDark
                ? NSColor.systemGreen
                : NSColor(srgbRed: 0.11, green: 0.44, blue: 0.17, alpha: 1.0)
            let green = NSImage(size: size, flipped: false) { rect in
                fill.setFill()
                rect.fill()
                base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
                // Blocked is orange and also carries a small "!" dot, so it
                // does not rest on telling orange from green.
                if blocked {
                    let d = min(rect.width, rect.height) * 0.42
                    let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
                    fill.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                    NSColor.white.setFill()
                    let bar = NSRect(x: dot.midX - d * 0.07, y: dot.minY + d * 0.38, width: d * 0.14, height: d * 0.42)
                    NSBezierPath(rect: bar).fill()
                    NSBezierPath(ovalIn: NSRect(x: dot.midX - d * 0.08, y: dot.minY + d * 0.14, width: d * 0.16, height: d * 0.16)).fill()
                } else if NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor {
                    // Running is green; with Differentiate Without Color it
                    // also carries a small play mark, as blocked has its "!".
                    let d = min(rect.width, rect.height) * 0.42
                    let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
                    fill.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                    NSColor.white.setFill()
                    let tri = NSBezierPath()
                    tri.move(to: NSPoint(x: dot.minX + d * 0.36, y: dot.minY + d * 0.26))
                    tri.line(to: NSPoint(x: dot.minX + d * 0.36, y: dot.maxY - d * 0.26))
                    tri.line(to: NSPoint(x: dot.maxX - d * 0.26, y: dot.midY))
                    tri.close()
                    tri.fill()
                }
                return true
            }
            green.isTemplate = false
            green.accessibilityDescription = blocked
                ? String(localized: "InputConfig (running, Accessibility is off)")
                : String(localized: "InputConfig (running)")
            return green
        } else {
            let template = base.copy() as? NSImage
            template?.isTemplate = true
            template?.size = size
            template?.accessibilityDescription = "InputConfig"
            return template
        }
    }

    /// Show or hide the status item without removing it. Safe to call from
    /// SwiftUI .onChange handlers.
    func setVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
            return
        }
        guard let presetStore, let mappingEngine else { return }

        // Keep the CPU/RAM readout live while the popover is open.
        SystemStatsService.shared.retain()

        let root = MenuBarPopoverView(
            presetStore: presetStore,
            mappingEngine: mappingEngine,
            controllerService: controllerService,
            onToggle: { [weak self] preset in self?.toggle(preset) },
            onNewPreset: { [weak self] in self?.dismissThen { self?.newPreset() } },
            onSmartMaker: { [weak self] in self?.dismissThen { self?.openSmartMaker() } },
            onStatistics: { [weak self] in self?.dismissThen { self?.openStatistics() } },
            onOpen: { [weak self] in self?.dismissThen { self?.openMainWindow() } },
            onSettings: { [weak self] in self?.dismissThen { self?.openSettings() } },
            onHelp: { [weak self] in self?.dismissThen { self?.openHelpGuides() } },
            onSupport: { [weak self] in self?.dismissThen { self?.openTipJar() } },
            onQuit: { [weak self] in self?.quitApp() }
        ).appAccessibility()
        let hosting = NSHostingController(rootView: root.reduceMotionFriendly())
        hosting.sizingOptions = [.preferredContentSize]
        pop.contentViewController = hosting
        // The app's own Reduce motion switch too, which reaches only SwiftUI.
        pop.animates = !(AppA11y.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Make the popover key so its SwiftUI buttons receive clicks.
        pop.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func popoverDidClose(_ notification: Notification) {
        SystemStatsService.shared.release()
    }

    private func dismissThen(_ action: @escaping () -> Void) {
        popover?.performClose(nil)
        action()
    }

    /// Toggle a preset from the popover, then close it (like picking a menu item).
    private func toggle(_ preset: Preset) {
        guard let mappingEngine, let presetStore else { return }
        if preset.isActive {
            mappingEngine.stop()
            presetStore.deactivateAll()
        } else if preset.isRunnable {
            Self.activate(preset, store: presetStore, engine: mappingEngine)
        }
        popover?.performClose(nil)
    }

    // MARK: - App actions (controller-triggered runtime control)

    /// Perform an internal app action fired by a binding's App Action output.
    /// Lives here because this controller already holds app-lifetime
    /// references to the store and engine and performs the same activation
    /// work for menu clicks, so the feature works with the window closed.
    func performAppAction(_ kind: AppActionKind, targetPresetID: UUID?, sourceJoystick: Int = 0) {
        guard let store = presetStore, let engine = mappingEngine else { return }
        ActivityLog.shared.event("Engine", "App action: \(kind.displayName)", slot: sourceJoystick)
        switch kind {
        case .rezeroMotion:
            // The controller that pressed the button gets its resting zero
            // snapshotted, exactly like the editor's Quick Zero button. It
            // should be at rest when this fires; a paddle or an unused
            // button next to the aim stick is the usual home for it.
            controllerService?.rezeroMotion(slot: sourceJoystick)
            engine.reanchorMotion()
        case .centerPointer:
            InputSimulator.shared.centerPointerOnCurrentScreen()
            engine.reanchorMotion()
        case .activatePreset:
            guard let id = targetPresetID,
                  let preset = store.presets.first(where: { $0.id == id }),
                  preset.isRunnable,
                  store.activePresetId != preset.id else { return }
            Self.activate(preset, store: store, engine: engine, background: true)
        case .nextPreset, .previousPreset:
            // Cycles within the active preset's folder, in sidebar order, so
            // a button can step through the two or three layouts someone
            // actually uses rather than every preset installed. An ungrouped
            // preset, or none active, cycles through the whole list.
            let active = store.presets.first { $0.id == store.activePresetId }
            // An import not yet reviewed refuses a background start, and the
            // cycle stuck on it; it is left out until it has been started
            // once. Left out before the folder is judged, so a folder whose
            // only other preset is one cycles the whole library instead.
            func usableHere(_ p: Preset) -> Bool {
                p.isRunnable && (!store.isUnreviewedImport(p.id) || p.id == store.activePresetId)
            }
            let usable: [Preset] = {
                if let folder = active?.groupID {
                    let inFolder = store.presets(in: folder).filter(usableHere)
                    if inFolder.count > 1 { return inFolder }
                }
                return store.presetsInSidebarOrder.filter(usableHere)
            }()
            guard !usable.isEmpty else { return }
            let step = (kind == .nextPreset) ? 1 : -1
            let nextIndex: Int
            if let current = usable.firstIndex(where: { $0.id == store.activePresetId }) {
                nextIndex = (current + step + usable.count) % usable.count
            } else {
                nextIndex = (kind == .nextPreset) ? 0 : usable.count - 1
            }
            let preset = usable[nextIndex]
            // The only one: starting it again would only restart it.
            if preset.id == store.activePresetId, engine.isRunning { return }
            Self.activate(preset, store: store, engine: engine, background: true)
        case .deactivate:
            engine.stop()
            store.deactivateAll()
        case .togglePauseOutputs:
            // Works in the editor too: a running preset keeps working there.
            engine.outputsPaused.toggle()
            AccessibilityNotification.Announcement(engine.outputsPaused ? String(localized: "Outputs paused") : String(localized: "Outputs resumed")).post()
        case .holdMuteMotion, .toggleMotion, .holdEnableMotion:
            // Held-only; MappingEngine gates motion per poll frame.
            break
        case .emergencyStop:
            EmergencyStopService.shared.stop(reason: .binding)
        }
    }

    // MARK: - Window actions

    /// Bring the main window up, recreating it if every window was closed.
    func showMainWindow() { openMainWindow() }

    /// The running preset, which a restart for a language change starts again.
    var activePresetID: UUID? { presetStore?.activePresetId }

    /// A menu command the library window carries out. With that window
    /// closed (closing it does not quit), nobody heard the notification and
    /// the command did nothing, so the window opens first.
    func postToMainWindow(_ name: Notification.Name, object: Any? = nil) {
        if let window = Self.mainWindow, window.isVisible {
            // In front first, so a dialog or sheet the command opens is where
            // the keyboard and VoiceOver are, not behind Help or Settings.
            if !window.isKeyWindow { NSApp.activate(); window.makeKeyAndOrderFront(nil) }
            NotificationCenter.default.post(name: name, object: object)
            return
        }
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: name, object: object)
        }
    }

    /// Opens the main window scene. Set from the main window's view, the
    /// only place SwiftUI hands out `openWindow`; it keeps working after
    /// that window has closed.
    var openMainScene: (() -> Void)?

    /// The library window, told apart by its scene id. Matching "any window
    /// that can be main" raised Help, the Tip Jar, the Test Bench, or
    /// Settings instead whenever one of those was open.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && !($0 is NSPanel) }
            ?? NSApp.windows.first { $0.title == "InputConfig" && $0.canBecomeMain && !($0 is NSPanel) }
    }

    @objc private func openMainWindow() {
        NSApp.activate()
        if let window = Self.mainWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Closed: SwiftUI recreates it. (Calling the reopen delegate
        // method directly created nothing.)
        if let open = openMainScene {
            open()
        } else if let window = Self.mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            Self.openMainFromWindowMenu()
        }
    }

    /// No window has appeared yet this run, so nothing has handed over
    /// SwiftUI's openWindow. The Window menu's Show Main Window item
    /// (`OpenMainWindowCommand`) holds one from launch; choosing it creates
    /// the window.
    @discardableResult
    private static func openMainFromWindowMenu() -> Bool {
        let title = OpenMainWindowCommand.title
        let menus = [NSApp.windowsMenu].compactMap { $0 } + (NSApp.mainMenu?.items.compactMap(\.submenu) ?? [])
        for menu in menus {
            if let index = menu.items.firstIndex(where: { $0.title == title && $0.action != nil }) {
                menu.performActionForItem(at: index)
                return true
            }
        }
        return false
    }

    /// Settings is a sheet on the main window: bring the window up, then
    /// open it there. The old `showSettingsWindow:` action is ignored on
    /// macOS 14 and later, so the popover's gear did nothing.
    /// Something the main window should do once it is up: open Settings, or
    /// make a new preset. Taken by whichever comes first, the window's
    /// appearance or the notification below, so it runs exactly once even
    /// when a recreated window subscribes after the notification was sent.
    enum PendingMainAction { case settings, newPreset, statistics, smartMaker, whatsNew, about }
    static var pendingMainAction: PendingMainAction?
    static func takePendingMainAction(_ kind: PendingMainAction) -> Bool {
        guard pendingMainAction == kind else { return false }
        pendingMainAction = nil
        return true
    }

    @objc private func openSettings() {
        Self.pendingMainAction = .settings
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .inputConfigOpenSettings, object: nil)
        }
    }

    @objc private func openHelpGuides() {
        NSApp.activate()
        HelpGuideWindowController.shared.show()
    }

    /// Bring the main window forward and open Settings on the About tab.
    /// The Help window is its own NSWindow and cannot reach ContentView's
    /// sheet state directly, so it routes through here the way the menu bar
    /// already does for Statistics.
    func openAboutPage() {
        // Taken by the window when it appears, for a window that was closed
        // and subscribes after the notification went out.
        Self.pendingMainAction = .about
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .inputConfigOpenAbout, object: nil)
        }
    }

    /// Bring the main window forward and open the Statistics sheet.
    @objc private func openStatistics() {
        Self.pendingMainAction = .statistics
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .inputConfigShowStats, object: nil)
        }
    }

    /// Bring the main window forward and open the Smart Preset Maker.
    @objc private func openSmartMaker() {
        Self.pendingMainAction = .smartMaker
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .inputConfigOpenSmartMaker, object: nil)
        }
    }

    /// Create a fresh preset and bring the app forward to edit it.
    @objc private func newPreset() {
        Self.pendingMainAction = .newPreset
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .inputConfigNewPreset, object: nil)
        }
    }

    /// Cmd-N: the same path, from the File menu.
    func newPresetFromMenu() { newPreset() }

    @objc private func openTipJar() {
        NSApp.activate()
        TipJarWindowController.shared.show()
    }

    @objc private func quitApp() {
        // Through the same path as the Quit menu item: an open editor is
        // saved or discarded first, and a sheet does not stall the quit.
        if let quit = QuitCoordinator.shared { quit.requestQuit() } else { NSApplication.shared.terminate(nil) }
    }
}

// MARK: - Popover UI (YapToText menu bar language)

/// The menu bar popover, a close replica of YapToText's so the family shares
/// one menu-bar language: the SAME frosted window container glass, the SAME
/// spacing (VStack spacing 10, padding 12, width 320), the SAME component
/// tokens (translucent header action pill, capsule selector pills, innerWell
/// square quick-actions, bare-icon footer). Only the content differs, mapped
/// onto InputConfig's domain: the Mode/Input pills become Preset/Controller,
/// the record pill becomes Start/Stop, and Recent becomes engine Status.
private struct MenuBarPopoverView: View {
    /// Wider at a large Text Size, so the preset's name and the header fit.
    @Environment(\.appTextScale) private var popoverTextScale
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var mappingEngine: MappingEngine
    weak var controllerService: GameControllerService?
    let onToggle: (Preset) -> Void
    let onNewPreset: () -> Void
    let onSmartMaker: () -> Void
    let onStatistics: () -> Void
    let onOpen: () -> Void
    let onSettings: () -> Void
    let onHelp: () -> Void
    let onSupport: () -> Void
    let onQuit: () -> Void

    @ObservedObject private var stats = SystemStatsService.shared
    @ObservedObject private var permission = AccessibilityPermissionService.shared
    private var activePreset: Preset? { presetStore.presets.first { $0.isActive } }
    private var running: Bool { mappingEngine.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            selectorRow
            quickActions
            Divider()
            statusSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320 * min(max(1, popoverTextScale), 1.6))
        .symbolRenderingMode(.hierarchical)
        .focusRingForKeyboardUsers()
        // THE glass: the same window-container frosted material YapToText uses,
        // which fills the whole popover window (not just behind the content the
        // way a plain .background does), so the liquid-glass look matches.
        .menuBarGlass()
    }

    // MARK: Header - brand + the one action (Start/Stop), like the record pill

    private var header: some View {
        HStack(spacing: 8) {
            ControllerGlyph(height: 26)
                .iconTint(running ? .green : .green)
                .accessibilityHidden(true)
            Text("InputConfig").font(.headline)
            // The running build, right where you look while testing - text
            // only, no button. Same placement as YapToText's menu bar.
            Text(Changelog.currentVersion)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.hint)
                .padding(.top, 2)
            Spacer()
            enginePill
        }
    }

    @ViewBuilder private var enginePill: some View {
        if let active = activePreset {
            Button { onToggle(active) } label: {
                pill(icon: "stop.fill", text: "Stop", tint: .icStop)
            }
            .buttonStyle(.plain).help("Stop \(active.shownName)")
            .accessibilityLabel("Stop the running preset")
            .voiceNames("Stop")
        } else {
            let target = firstRunnable
            Button { if let t = target { onToggle(t) } } label: {
                pill(icon: "play.fill", text: "Start", tint: .green)
            }
            .buttonStyle(.plain).disabled(target == nil).opacity(target == nil ? 0.5 : 1)
            .help(target.map { String(localized: "Start \($0.shownName)") } ?? String(localized: "Add a preset first"))
            .accessibilityLabel(target.map { String(localized: "Start \($0.shownName)") } ?? String(localized: "Add a preset first"))
            .voiceNames("Start")
        }
    }

    private func pill(icon: String, text: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.caption.weight(.semibold))
        }
        // White, or black where white would not read on the tint (green).
        .foregroundStyle(tint == .green ? Color.readableLabel(red: 0.20, green: 0.78, blue: 0.35) : .white)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(tint.opacity(tint == .green ? 1 : 0.72), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
        .contentShape(Capsule())
    }

    private var firstRunnable: Preset? {
        presetStore.lastActivatedPresetId
            .flatMap { id in presetStore.presets.first { $0.id == id && $0.isRunnable } }
            ?? presetStore.presets.first { $0.isRunnable }
    }

    // MARK: Selector row - two capsule pills (Preset + Controller), like Mode + Input

    private var selectorRow: some View {
        HStack(spacing: 8) {
            Menu {
                // Starred presets first; with Favorites Only on (the same
                // switch as the sidebar's star), nothing else.
                let favorites = presetStore.favoritePresets
                if !favorites.isEmpty {
                    Section("Favorites") { ForEach(favorites) { presetMenuButton($0) } }
                }
                if favorites.isEmpty || !presetStore.showFavoritesOnly {
                    ForEach(presetStore.inSidebarOrder(presetStore.groups)) { group in
                        let ps = presetStore.presets(in: group.id)
                        if !ps.isEmpty { Section(ShippedText.t(group.name)) { ForEach(ps) { presetMenuButton($0) } } }
                    }
                    let ungrouped = presetStore.presets(in: nil)
                    if !ungrouped.isEmpty {
                        Section(presetStore.groups.isEmpty ? String(localized: "Presets") : String(localized: "Ungrouped")) {
                            ForEach(ungrouped) { presetMenuButton($0) }
                        }
                    }
                }
                if !favorites.isEmpty {
                    Divider()
                    Toggle("Favorites Only", isOn: $presetStore.showFavoritesOnly)
                }
            } label: {
                selectorLabel(String(localized: "Preset"), icon: "slider.horizontal.3", value: activePreset?.shownName ?? String(localized: "No preset"))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            // The name too, since a long one is cut off on the pill.
            .help(String(localized: "\(String(localized: "Switch the active preset")): \(activePreset?.shownName ?? String(localized: "No preset"))"))
            .accessibilityInputLabels([Text(activePreset?.shownName ?? String(localized: "No preset")), Text("Preset")])

            Menu {
                if let svc = controllerService, !svc.controllerDetails.isEmpty {
                    Section("Connected") {
                        ForEach(svc.controllerDetails.keys.sorted(), id: \.self) { slot in
                            if let info = svc.controllerDetails[slot] {
                                Button {} label: {
                                    if info.hasBattery, let level = info.batteryLevel {
                                        Label("\(info.name)  \(Int(level * 100))%", systemImage: "gamecontroller")
                                    } else {
                                        Label(info.name, systemImage: "gamecontroller")
                                    }
                                }.disabled(true)
                            }
                        }
                    }
                } else {
                    Button("No controller connected") {}.disabled(true)
                }
            } label: {
                selectorLabel(String(localized: "Controller"), icon: "gamecontroller.fill", value: primaryControllerName)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help(String(localized: "\(String(localized: "Connected controllers")): \(primaryControllerName)"))
            .accessibilityInputLabels([Text(primaryControllerName), Text("Controller")])
        }
    }

    @ViewBuilder private func presetMenuButton(_ preset: Preset) -> some View {
        Button { onToggle(preset) } label: {
            Label(preset.shownName,
                  systemImage: preset.isActive ? "checkmark"
                      : (preset.isRunnable ? "circle" : "circle.dashed"))
        }
        // The running one in words, not only by its checkmark.
        .accessibilityLabel(preset.isActive ? String(localized: "\(preset.shownName), running") : preset.shownName)
        .disabled(!preset.isRunnable && !preset.isActive)
    }

    private var primaryControllerName: String {
        guard let d = controllerService?.controllerDetails, !d.isEmpty else { return String(localized: "No controller") }
        if d.count == 1, let info = d.first?.value { return info.name }
        return String(localized: "\(d.count) controllers")
    }

    /// The capsule selector pill, identical to YapToText's selectorLabel token.
    private func selectorLabel(_ label: String, icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).iconTint(.green)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(label): \(value)")
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }

    // MARK: Quick actions - innerWell square buttons, identical token to YapToText

    private var quickActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                squareButton("New Preset", "plus.rectangle.on.rectangle", action: onNewPreset)
                squareButton("Smart Preset", "wand.and.stars", action: onSmartMaker)
                squareButton("Statistics", "chart.line.uptrend.xyaxis", action: onStatistics)
            }
            emergencyStopButton
        }
    }

    /// Always present, whether or not anything is running, so it is in the
    /// same place every time someone reaches for it. Shows every way to
    /// reach it right now: the shortcut, the controller hold, and any
    /// control the active preset binds to it.
    private var emergencyStopButton: some View {
        let service = EmergencyStopService.shared
        // The live registration, not the setting: a chord another app
        // holds does nothing, so it is not offered as a way to stop.
        let shortcut = service.isRegistered ? service.spec.displayString : nil
        var ways: [String] = []
        if service.controllerHoldEnabled {
            func label(_ index: Int) -> String {
                // Its everyday name with Start beside it ("Back and Start"), as the main window says.
                EmergencyStopService.holdButtonName(index, short: service.holdNeedsStart)
            }
            // Start too when the hold needs it, as it does by default.
            let name = service.holdNeedsStart
                ? LocalizedList.and([label(service.controllerButton), label(EmergencyStopService.startButton)])
                : label(service.controllerButton)
            let secsText = service.holdSeconds.formatted(.number.precision(.fractionLength(0...1)))
            ways.append(String(localized: "Hold \(name) \(secsText) s") + service.accessControllerHoldNote)
        }
        let presetWays = activePresetEmergencyInputs
        if !presetWays.isEmpty {
            let presetList = presetWays.joined(separator: ", ")
            ways.append(String(localized: "This preset: \(presetList)"))
        }
        return Button {
            service.stop(reason: .menu)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Emergency Stop")
                        .font(.system(size: 12, weight: .semibold))
                    if !ways.isEmpty {
                        Text(ways.joined(separator: ", "))
                            .font(.system(size: 10))
                            // The gray label color, not a pale shade of the
                            // row's red: the ways to stop read at about 2:1.
                            .foregroundStyle(Color.secondary)
                            // As many lines as it needs: the hold time and the
                            // Access Controller socket must not be cut off.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Color.secondary)
                        .accessibilityLabel(service.spec.spokenString)
                }
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(minHeight: ways.isEmpty ? 34 : 42)
            .padding(.vertical, ways.isEmpty ? 0 : 2)
            .innerWell(radius: 9)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Stop the engine and release every held key, button, and note.")
        // One short name to say, with the ways to stop as its value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Emergency Stop")
        .accessibilityValue((ways + [shortcut.map { _ in service.spec.spokenString + service.voiceOverChordNote }].compactMap { $0 }).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { service.stop(reason: .menu) }
        .voiceNames("Emergency Stop")
    }

    /// Controls in the active preset that are bound to Emergency Stop, as
    /// the labels the editor uses for them.
    private var activePresetEmergencyInputs: [String] {
        guard let preset = activePreset else { return [] }
        let slots = controllerService?.effectiveSlots(for: preset.joysticks) ?? [:]
        return preset.joysticks.enumerated().flatMap { g, joystick in
            let naming = slots[g].flatMap { controllerService?.naming(forSlot: $0, presetFamily: preset.buttonFamily) }
                ?? (family: preset.buttonFamily, model: ButtonNames.ModelNames.none)
            return joystick.bindings
                .filter { b in b.outputs.contains { $0.type == .appAction && $0.appActionKind == .emergencyStop } }
                .map { b in ButtonNames.inputName(b.input, family: naming.family, model: naming.model) }
        }
    }

    private func squareButton(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18)).iconTint(.green).accessibilityHidden(true)
                // Two centered lines for a long translation ("Smart
                // forhåndsinnstilling"), still inside the 62 point square.
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(minHeight: 62)
            .innerWell(radius: 11)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).help(title)
    }

    // MARK: Status - the "Recent" slot, showing engine state (InputConfig domain)

    private var statusSection: some View {
        let paused = mappingEngine.outputsPaused
        let dot: Color = running ? (paused ? .orange : .green) : .secondary
        let label = running
            ? (paused ? String(localized: "Outputs paused") : String(localized: "Engine running \(mappingEngine.currentPollHz) Hz"))
            : String(localized: "Engine idle")
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Status").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 6) {
                Circle().fill(dot.opacity(0.85)).frame(width: 7, height: 7)
                Text(label).font(.caption)
                Spacer(minLength: 8)
                Text(String(format: String(localized: "CPU %.0f%%, RAM %.0f MB"), locale: .current,
                            stats.current.smoothedCpuPercent,
                            Double(stats.current.residentMemoryBytes) / 1_048_576.0))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.hint)
            }
            if running && !permission.isTrusted && activePreset?.needsAccessibility == true {
                Button {
                    // requestAccess adds InputConfig's row to the list and
                    // opens the pane; opening the pane alone could show a
                    // list with no InputConfig in it.
                    permission.requestAccess()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                        Text("Accessibility is off, so this preset's keys and clicks go nowhere. Turn it on in System Settings.")
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
                .help("Open System Settings, Privacy & Security, Accessibility")
            }
            if running, let preset = activePreset, let svc = controllerService {
                // A group pinned to a controller that is away reads nothing
                // while another pad is here: the preset looked like it ran.
                ForEach(preset.joysticks.indices.filter { svc.waitingDeviceName(forGroup: $0, in: preset.joysticks) != nil }, id: \.self) { index in
                    let waitingName = preset.joysticks[index].shownCustomName ?? String(localized: "its controller")
                    Button {
                        var updated = preset
                        guard let name = svc.standInPadName(forGroup: index, in: preset.joysticks) else {
                            GameControllerService.sayEveryPadInUse(); return
                        }
                        updated.joysticks[index].customName = name
                        updated.joysticks[index].inputKind = .controller
                        updated.modifiedAt = Date()
                        presetStore.savePreset(updated)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                            Text("Waiting for \(waitingName). Click to use the connected controller instead.")
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Sets this input device to the controller connected now")
                }
            }
        }
    }

    // MARK: Footer - four bare icons: meta left, go-to-app right (YapToText layout)

    private var footer: some View {
        HStack(spacing: 16) {
            MenuFooterIcon(symbol: "power", help: "Quit InputConfig", action: onQuit)
            MenuFooterIcon(symbol: "heart.fill", help: "Donate to InputConfig", tint: .pink, action: onSupport)
            Spacer()
            // The Devices menu, here too: with the Dock icon off the app has
            // no menu bar, and connecting a pad or a Stream Deck by hand was
            // out of reach.
            if let svc = controllerService {
                Menu {
                    DevicesMenuContent(controllerService: svc)
                } label: {
                    Image(systemName: "cable.connector").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Devices")
                .accessibilityLabel("Devices")
            }
            MenuFooterIcon(symbol: "sparkles", help: "What's New in InputConfig") {
                MenuBarController.shared.showWhatsNew()
            }
            MenuFooterIcon(symbol: "macwindow", help: "Open InputConfig", action: onOpen)
            MenuFooterIcon(symbol: "gearshape", help: "Settings", action: onSettings)
        }
        .font(.body)
    }
}

private extension View {
    /// The family menu-bar window glass. On macOS 15+ this is the true
    /// window-container frosted material (fills the whole popover window,
    /// matching YapToText); on the macOS 14 App Store floor it falls back to a
    /// plain material background behind the content.
    @ViewBuilder func menuBarGlass() -> some View {
        if AppA11y.reduceTransparency {
            background(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 15.0, *) {
            containerBackground(.ultraThinMaterial, for: .window)
        } else {
            background(.ultraThinMaterial)
        }
    }
}

/// A footer icon button: the shared hover fill and, for colored icons, the
/// shared iconTint transparency. Matches YapToText's footer icon language.
private struct MenuFooterIcon: View {
    let symbol: String
    let help: LocalizedStringKey
    var tint: Color? = nil
    let action: () -> Void

    // Bare icon button, identical to YapToText's footer buttons: no padding,
    // no hover fill, no enlarged hit shape. This is what makes the glyphs sit
    // flush at the 12pt container margin with a true 16pt gap (the padded
    // version inflated them and pushed the corner icons inward).
    var body: some View {
        Button(action: action) { glyph }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }

    @ViewBuilder private var glyph: some View {
        if let tint {
            Image(systemName: symbol).iconTint(tint)
        } else {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}


/// What sits in the menu bar. People use InputConfig for very different
/// things (a game pad, a MIDI deck, an accessibility switch, a hearing aid),
/// so the glyph can say which.
enum MenuBarIconChoice: String, CaseIterable, Identifiable {
    case controller, gamepad, arcade, dpad, keyboard, mouse, piano, note, tap, wheelchair, headphones, pointer

    var id: String { rawValue }
    static let storageKey = "InputConfig.menuBarIcon"

    /// SF Symbol name; the default uses the app's own controller artwork.
    var symbol: String {
        switch self {
        case .controller: return "gamecontroller"
        case .gamepad: return "gamecontroller.fill"
        case .arcade: return "arcade.stick.console.fill"
        case .dpad: return "dpad.fill"
        case .keyboard: return "keyboard.fill"
        case .mouse: return "computermouse.fill"
        case .piano: return "pianokeys"
        case .note: return "music.note"
        case .tap: return "hand.tap.fill"
        case .wheelchair: return "figure.roll"
        case .headphones: return "headphones"
        case .pointer: return "cursorarrow.click.2"
        }
    }

    var label: String {
        switch self {
        case .controller: return "InputConfig"
        case .gamepad: return String(localized: "Gamepad")
        case .arcade: return String(localized: "Arcade stick")
        case .dpad: return String(localized: "D-pad")
        case .keyboard: return String(localized: "Keyboard")
        case .mouse: return String(localized: "Mouse")
        case .piano: return String(localized: "Piano keys")
        case .note: return String(localized: "Music")
        case .tap: return String(localized: "Tap")
        case .wheelchair: return String(localized: "Accessibility")
        case .headphones: return String(localized: "Headphones")
        case .pointer: return String(localized: "Pointer")
        }
    }
}

/// A short line shown over every app for a few seconds, for cues that were
/// otherwise only heard or spoken to VoiceOver: the emergency stop, its
/// one-second warning, a start by the controller hold and a refused start.
/// It never takes focus or clicks.
@MainActor
final class StatusHUD {
    static let shared = StatusHUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, seconds: TimeInterval = 6) {
        #if DEBUG
        if TestCapture.active { TestCapture.note("notice \(text)"); return }
        #endif
        let scale = AppA11y.scale(forStep: UserDefaults.standard.integer(forKey: "InputConfig.a11y.textSize"))
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 15 * scale, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 420 * scale
        let size = label.fittingSize
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size.width + 36, height: size.height + 24))
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        label.frame = NSRect(x: 18, y: 12, width: size.width, height: size.height)
        box.addSubview(label)
        let p = panel ?? NSPanel(contentRect: box.frame, styleMask: [.nonactivatingPanel, .borderless],
                                 backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        // Shown while another app is in front, which is when it is needed.
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = box
        p.setContentSize(box.frame.size)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - box.frame.width / 2, y: f.maxY - box.frame.height - 24))
        }
        p.orderFrontRegardless()
        panel = p
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
