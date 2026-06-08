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

            let deactivate = NSMenuItem(title: "Deactivate",
                                        action: #selector(deactivateActive),
                                        keyEquivalent: "")
            deactivate.target = self
            menu.addItem(deactivate)
        } else {
            let none = NSMenuItem(title: "No preset active", action: nil, keyEquivalent: "")
            none.attributedTitle = subtitleString("No preset active")
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
        let open = NSMenuItem(title: "Open InputConfig",
                              action: #selector(openMainWindow),
                              keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let help = NSMenuItem(title: "Help Guides",
                              action: #selector(openHelpGuides),
                              keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        let testBench = NSMenuItem(title: "Test Bench",
                                   action: #selector(openTestBench),
                                   keyEquivalent: "")
        testBench.target = self
        menu.addItem(testBench)

        let tip = NSMenuItem(title: "Support InputConfig...",
                             action: #selector(openTipJar),
                             keyEquivalent: "")
        tip.target = self
        menu.addItem(tip)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit InputConfig",
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
        let pollHz = mappingEngine?.currentPollHz ?? 0

        let engineLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        engineLine.attributedTitle = statusDotString(
            running ? .systemGreen : .secondaryLabelColor,
            text: running
                ? "Engine running \u{00B7} \(pollHz) Hz"
                : "Engine idle")
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
        let header = NSMenuItem(title: "Controllers", action: nil, keyEquivalent: "")
        header.attributedTitle = sectionHeaderString("Controllers")
        header.isEnabled = false
        menu.addItem(header)

        guard let svc = controllerService,
              !svc.controllerDetails.isEmpty else {
            let none = NSMenuItem(title: "    None connected",
                                  action: nil, keyEquivalent: "")
            none.attributedTitle = subtitleString("    None connected")
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

    @objc private func deactivateActive() {
        guard let active = presetStore?.presets.first(where: { $0.isActive }),
              let mappingEngine else { return }
        mappingEngine.stop()
        presetStore?.deactivateAll()
        _ = active
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "InputConfig"
            || window.contentView != nil {
            window.makeKeyAndOrderFront(nil)
            break
        }
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
