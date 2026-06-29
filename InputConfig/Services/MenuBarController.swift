import AppKit
import Combine
import SwiftUI

/// AppKit-backed menu bar status item. Replaces SwiftUI's MenuBarExtra,
/// which couldn't be hidden at runtime without triggering an infinite
/// scenesDidChange loop on macOS 26. Because NSStatusItem.isVisible lives
/// outside the SwiftUI Scene tree, toggling it doesn't cascade into a
/// Scene rebuild.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    static let shared = MenuBarController()

    static let defaultsKey = "InputConfig.showMenuBarIcon"

    private var statusItem: NSStatusItem?
    private weak var presetStore: PresetStore?
    private weak var mappingEngine: MappingEngine?
    private weak var controllerService: GameControllerService?
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        super.init()
    }

    /// Create the status item and seed visibility from defaults. Called once
    /// from app startup with live references to the stores the menu reads.
    func install(presetStore: PresetStore, mappingEngine: MappingEngine,
                 controllerService: GameControllerService? = nil) {
        guard statusItem == nil else { return }
        self.presetStore = presetStore
        self.mappingEngine = mappingEngine
        self.controllerService = controllerService

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "gamecontroller",
                                accessibilityDescription: "InputConfig")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        let visible = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
        item.isVisible = visible

        // Live icon: filled glyph while a preset is running so the menu bar
        // shows at a glance whether mappings are on.
        mappingEngine.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let button = self?.statusItem?.button else { return }
                let name = running ? "gamecontroller.fill" : "gamecontroller"
                let image = NSImage(systemSymbolName: name,
                                    accessibilityDescription: "InputConfig")
                image?.isTemplate = true
                button.image = image
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
            .sink { [weak self] _ in
                guard let self,
                      let presetStore = self.presetStore,
                      let mappingEngine = self.mappingEngine else { return }
                let windowAlive = NSApp.windows.contains {
                    $0.canBecomeMain && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized)
                }
                if windowAlive { return }
                if presetStore.presets.contains(where: { $0.isActive }) {
                    mappingEngine.stop()
                    presetStore.deactivateAll()
                } else {
                    let target = presetStore.lastActivatedPresetId
                        .flatMap { id in presetStore.presets.first(where: { $0.id == id }) }
                        ?? presetStore.presets.first(where: { p in
                            p.joysticks.contains { !$0.bindings.isEmpty }
                        })
                    if let target {
                        mappingEngine.stop()
                        presetStore.activatePreset(target)
                        mappingEngine.start(with: target)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Show or hide the status item without removing it. Safe to call from
    /// SwiftUI .onChange handlers.
    func setVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let presetStore else { return }

        // ── Section 1: Active session header ─────────────────────
        let active = presetStore.presets.first(where: { $0.isActive })

        if let active {
            let header = NSMenuItem()
            header.attributedTitle = activePresetHeader(active.name)
            menu.addItem(header)
            // Tag / description line under the active preset name.
            if !active.tag.isEmpty {
                let tagItem = NSMenuItem(title: "    \(active.tag)",
                                         action: nil, keyEquivalent: "")
                tagItem.isEnabled = false
                tagItem.attributedTitle = subtitleString("    " + active.tag)
                menu.addItem(tagItem)
            }
            // Binding count summary.
            let total = active.joysticks.reduce(0) { $0 + $1.bindings.count }
            let summary = NSMenuItem(
                title: "    \(total) \(total == 1 ? "binding" : "bindings") across \(active.joysticks.count) \(active.joysticks.count == 1 ? "slot" : "slots")",
                action: nil, keyEquivalent: "")
            summary.attributedTitle = subtitleString(summary.title)
            summary.isEnabled = false
            menu.addItem(summary)

            let deactivate = NSMenuItem(title: String(localized: "Deactivate"),
                                        action: #selector(deactivateActive),
                                        keyEquivalent: "")
            deactivate.target = self
            menu.addItem(deactivate)
        } else {
            let noneTitle = String(localized: "No preset active")
            let none = NSMenuItem(title: noneTitle, action: nil, keyEquivalent: "")
            none.attributedTitle = subtitleString(noneTitle)
            none.isEnabled = false
            menu.addItem(none)
        }

        menu.addItem(.separator())

        // ── Section 2: Engine + system status ─────────────────────
        appendStatusSection(to: menu)
        menu.addItem(.separator())

        // ── Section 3: Connected controllers ──────────────────────
        appendControllerSection(to: menu)

        // ── Section 4: Preset library, grouped ────────────────────
        appendPresetList(to: menu, presetStore: presetStore)

        // ── Section 5: App actions ────────────────────────────────
        let open = NSMenuItem(title: String(localized: "Open InputConfig"),
                              action: #selector(openMainWindow),
                              keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let help = NSMenuItem(title: String(localized: "Help Guides"),
                              action: #selector(openHelpGuides),
                              keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        let testBench = NSMenuItem(title: String(localized: "Test Bench"),
                                   action: #selector(openTestBench),
                                   keyEquivalent: "")
        testBench.target = self
        menu.addItem(testBench)

        let tip = NSMenuItem(title: String(localized: "Support InputConfig..."),
                             action: #selector(openTipJar),
                             keyEquivalent: "")
        tip.target = self
        menu.addItem(tip)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "Quit InputConfig"),
                              action: #selector(quitApp),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Menu sections

    /// Engine running / idle state plus a live CPU readout. Refreshed on
    /// every menu open (NSMenu calls menuNeedsUpdate before display),
    /// which is the natural cadence here - no extra timer needed.
    private func appendStatusSection(to menu: NSMenu) {
        let running = (mappingEngine?.isRunning ?? false)
        let paused = (mappingEngine?.outputsPaused ?? false)
        let pollHz = mappingEngine?.currentPollHz ?? 0

        let engineLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        engineLine.attributedTitle = statusDotString(
            running ? (paused ? .systemOrange : .systemGreen) : .secondaryLabelColor,
            text: running
                ? (paused ? String(localized: "Outputs paused (editor open)")
                          : String(localized: "Engine running \(pollHz) Hz"))
                : String(localized: "Engine idle"))
        engineLine.isEnabled = false
        menu.addItem(engineLine)

        let cpu = SystemStatsService.shared.current.smoothedCpuPercent
        let mem = SystemStatsService.shared.current.residentMemoryBytes
        let memMB = Double(mem) / 1_048_576.0
        let cpuLine = NSMenuItem(
            title: String(format: "    CPU %.1f%%  \u{00B7}  RAM %.0f MB", cpu, memMB),
            action: nil, keyEquivalent: "")
        cpuLine.attributedTitle = subtitleString(cpuLine.title)
        cpuLine.isEnabled = false
        menu.addItem(cpuLine)
    }

    /// One row per connected controller, with battery % when known.
    /// Shows "No controllers connected" when the slot dictionary is
    /// empty - keeps the menu non-confusing on launch.
    private func appendControllerSection(to menu: NSMenu) {
        let headerTitle = String(localized: "Controllers")
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.attributedTitle = sectionHeaderString(headerTitle)
        header.isEnabled = false
        menu.addItem(header)

        guard let svc = controllerService,
              !svc.controllerDetails.isEmpty else {
            let noneTitle = "    " + String(localized: "None connected")
            let none = NSMenuItem(title: noneTitle,
                                  action: nil, keyEquivalent: "")
            none.attributedTitle = subtitleString(noneTitle)
            none.isEnabled = false
            menu.addItem(none)
            menu.addItem(.separator())
            return
        }

        let sortedSlots = svc.controllerDetails.keys.sorted()
        for slot in sortedSlots {
            guard let info = svc.controllerDetails[slot] else { continue }
            var label = "    \(info.name)"
            if info.hasBattery, let level = info.batteryLevel {
                label += String(format: "  \u{00B7} %d%%", Int(level * 100))
            }
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.attributedTitle = subtitleString(label)
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    /// Show every preset, grouped into submenus by their PresetGroup.
    /// Ungrouped presets sit in their own bucket. Each item flips state
    /// to .on when its preset is active, so the menu doubles as a
    /// current-state indicator.
    private func appendPresetList(to menu: NSMenu, presetStore: PresetStore) {
        let presets = presetStore.presets
        guard !presets.isEmpty else { return }

        let header = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        header.attributedTitle = sectionHeaderString("Presets")
        header.isEnabled = false
        menu.addItem(header)

        // Render each group as a submenu.
        for group in presetStore.groups.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let groupPresets = presetStore.presets(in: group.id)
            guard !groupPresets.isEmpty else { continue }
            let submenu = NSMenu(title: group.name)
            for preset in groupPresets {
                submenu.addItem(presetMenuItem(for: preset))
            }
            let parent = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            // Folder symbol matches the sidebar so the visual language
            // carries over to the menu bar.
            parent.image = NSImage(systemSymbolName: "folder",
                                   accessibilityDescription: nil)
            menu.addItem(parent)
        }

        let ungrouped = presetStore.presets(in: nil)
        if !ungrouped.isEmpty {
            let submenu = NSMenu(title: "Ungrouped")
            for preset in ungrouped {
                submenu.addItem(presetMenuItem(for: preset))
            }
            let parent = NSMenuItem(title: "Ungrouped", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            parent.image = NSImage(systemSymbolName: "tray",
                                   accessibilityDescription: nil)
            menu.addItem(parent)
        }
        menu.addItem(.separator())
    }

    /// One preset row. Click to toggle (active → deactivate; inactive →
    /// activate). Active presets get a checkmark and a green dot.
    private func presetMenuItem(for preset: Preset) -> NSMenuItem {
        let item = NSMenuItem(title: preset.name,
                              action: #selector(activatePreset(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = preset.id
        if preset.isActive {
            item.state = .on
            item.attributedTitle = activePresetHeader(preset.name)
        } else if !preset.joysticks.contains(where: { !$0.bindings.isEmpty }) {
            // Clicking an empty preset silently did nothing (activation
            // early-returns); disable the row and say why instead.
            item.action = nil
            item.toolTip = String(localized: "No bindings yet. Open InputConfig to add some.")
        }
        return item
    }

    // MARK: - Actions

    @objc private func activatePreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = presetStore?.presets.first(where: { $0.id == id }),
              let mappingEngine else { return }
        if preset.isActive {
            mappingEngine.stop()
            presetStore?.deactivateAll()
        } else if !preset.joysticks.isEmpty {
            mappingEngine.stop()
            presetStore?.activatePreset(preset)
            mappingEngine.start(with: preset)
        }
    }

    // MARK: - App actions (controller-triggered runtime control)

    /// Perform an internal app action fired by a binding's App Action output.
    /// Lives here because this controller already holds app-lifetime
    /// references to the store and engine and performs the same activation
    /// work for menu clicks, so the feature works with the window closed.
    func performAppAction(_ kind: AppActionKind, targetPresetID: UUID?) {
        guard let store = presetStore, let engine = mappingEngine else { return }
        switch kind {
        case .activatePreset:
            guard let id = targetPresetID,
                  let preset = store.presets.first(where: { $0.id == id }),
                  preset.joysticks.contains(where: { !$0.bindings.isEmpty }),
                  store.activePresetId != preset.id else { return }
            engine.stop()
            store.activatePreset(preset)
            engine.start(with: preset)
        case .nextPreset, .previousPreset:
            let usable = store.presets.filter { p in
                p.joysticks.contains { !$0.bindings.isEmpty }
            }
            guard !usable.isEmpty else { return }
            let step = (kind == .nextPreset) ? 1 : -1
            let nextIndex: Int
            if let current = usable.firstIndex(where: { $0.id == store.activePresetId }) {
                nextIndex = (current + step + usable.count) % usable.count
            } else {
                nextIndex = (kind == .nextPreset) ? 0 : usable.count - 1
            }
            let preset = usable[nextIndex]
            engine.stop()
            store.activatePreset(preset)
            engine.start(with: preset)
        case .deactivate:
            engine.stop()
            store.deactivateAll()
        case .togglePauseOutputs:
            engine.outputsPaused.toggle()
        }
    }

    @objc private func deactivateActive() {
        guard presetStore?.presets.contains(where: { $0.isActive }) == true,
              let mappingEngine else { return }
        mappingEngine.stop()
        presetStore?.deactivateAll()
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Prefer a real main-capable window. The old predicate
        // (title match OR non-nil contentView) was true for nearly every
        // window, including panels and the status item's own window, so
        // it raised an arbitrary first match; and with every window
        // closed (normal for a menu bar app) it silently did nothing.
        if let visible = NSApp.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized)
        }) {
            if visible.isMiniaturized { visible.deminiaturize(nil) }
            visible.makeKeyAndOrderFront(nil)
            return
        }
        if let hidden = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            hidden.makeKeyAndOrderFront(nil)
            return
        }
        // No main window exists anymore: drive the same reopen path a
        // Dock-icon click uses so SwiftUI recreates the WindowGroup window.
        _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
    }

    @objc private func openHelpGuides() {
        NSApp.activate(ignoringOtherApps: true)
        HelpGuideWindowController.shared.show()
    }

    @objc private func openTestBench() {
        NSApp.activate(ignoringOtherApps: true)
        TestBenchWindowController.shared.show()
    }

    @objc private func openTipJar() {
        NSApp.activate(ignoringOtherApps: true)
        TipJarWindowController.shared.show()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func activePresetHeader(_ name: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let dot = NSAttributedString(
            string: "● ",
            attributes: [
                .foregroundColor: NSColor.systemGreen,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
        )
        result.append(dot)
        result.append(NSAttributedString(
            string: name,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            ]
        ))
        return result
    }

    /// Faded subtitle text used for the secondary lines (binding count,
    /// CPU readout, controller names). Smaller font + secondary label
    /// color so it visually steps down from the active-preset header.
    private func subtitleString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ])
    }

    /// Bold uppercase-ish section header (Controllers / Presets).
    private func sectionHeaderString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        ])
    }

    /// Inline colored dot followed by a label. Used for the engine
    /// running / idle line so the menu reads at a glance.
    private func statusDotString(_ color: NSColor, text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]))
        result.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]))
        return result
    }
}
