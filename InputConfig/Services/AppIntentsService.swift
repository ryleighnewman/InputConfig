import Foundation
import AppIntents
import AppKit

// App Intents: InputConfig's presets from outside its window. Siri ("Start
// Easy Browse in InputConfig"), the Shortcuts app (each intent is an action
// a shortcut can run, with a preset picked from a list), Spotlight, and
// Voice Control (a custom command can run a shortcut, and the App Shortcut
// phrases below are spoken as they are).
//
// Every intent performs on the main actor through the same path the menu
// bar and the preset hotkeys use (MenuBarController.activate, engine.stop,
// store.deactivateAll, EmergencyStopService.stop), as a background start:
// the first-start confirmation is honored, while the restrictive-preset
// confirmation and the Accessibility warning, alerts that would take the
// front from the app in use, are said in the dialog instead (startedDialog).

/// What Start says once the preset runs. The two alerts a click would show
/// (the pointer it holds, missing Accessibility) are not raised over the
/// app in use, so the dialog says them.
@MainActor
private func startedDialog(_ p: Preset, engine: MappingEngine) -> IntentDialog {
    // Held back as it starts: "Started" alone said it works while nothing fires.
    if engine.outputsPaused { return "\(p.shownName) is running, with its outputs paused." }
    if engine.isHeldByAppGate { return "\(p.shownName) is running, held back while an app it does not list is in front." }
    if engine.isSuspended { return "\(p.shownName) is running, held back for now." }
    if engine.missingInputPermission {
        return "Started \(p.shownName), but a permission its screen or voice rows need is missing, so they do nothing yet."
    }
    // Only for a preset that sends keys or clicks: a MIDI or light bar
    // preset needs no Accessibility.
    if p.needsAccessibility, !AXIsProcessTrusted() {
        return "Started \(p.shownName), but InputConfig does not have Accessibility, so its keys and clicks do not reach other apps yet."
    }
    if !PresetStore.pointerRestrictions(for: p).isEmpty {
        return "Started \(p.shownName). It holds the pointer while it runs; an emergency stop lets go of it."
    }
    return "Started \(p.shownName)."
}

/// A preset, as Siri and Shortcuts see it: its id, its name, its folder.
struct PresetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Preset")
    static let defaultQuery = PresetQuery()

    var id: UUID
    var name: String
    var folder: String?
    var isActive: Bool

    var displayRepresentation: DisplayRepresentation {
        if let folder, !folder.isEmpty {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(folder)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    @MainActor
    init(_ preset: Preset, store: PresetStore) {
        id = preset.id
        name = preset.shownName
        folder = preset.groupID.flatMap { gid in store.groups.first { $0.id == gid } }.map { ShippedText.t($0.name) }
        isActive = store.activePresetId == preset.id
    }
}

struct PresetQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        guard let store = AppState.current?.presetStore else { return [] }
        return identifiers.compactMap { id in store.presets.first { $0.id == id }.map { PresetEntity($0, store: store) } }
    }

    /// By name, the way the sidebar search matches: any word, in any order,
    /// accents and case ignored.
    @MainActor
    func entities(matching string: String) async throws -> [PresetEntity] {
        guard let store = AppState.current?.presetStore else { return [] }
        let hits = string.trimmingCharacters(in: .whitespaces).isEmpty ? store.presets : store.search(string)
        return store.inSidebarOrder(hits.filter { !store.isHiddenBuiltIn($0) }).map { PresetEntity($0, store: store) }
    }

    /// What Siri and Shortcuts offer before anything is typed: the presets
    /// started last, then the rest in sidebar order.
    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        guard let store = AppState.current?.presetStore else { return [] }
        var seen: Set<UUID> = []
        var out: [Preset] = []
        for p in store.recentPresets + store.inSidebarOrder(store.presets) where !store.isHiddenBuiltIn(p) && seen.insert(p.id).inserted {
            out.append(p)
        }
        return out.map { PresetEntity($0, store: store) }
    }
}

enum PresetIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotRunning
    case presetGone
    case notRunnable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotRunning: return "InputConfig is not open yet. Open it once, then try again."
        case .presetGone: return "That preset is not in the library any more."
        case .notRunnable(let name): return "\(name) has no rows to run."
        }
    }
}

/// The live store and engine, or the error Siri reads out.
@MainActor
private func liveApp() throws -> (store: PresetStore, engine: MappingEngine) {
    guard let app = AppState.current else { throw PresetIntentError.appNotRunning }
    VoicePhraseService.shared.holdForSpokenReply()
    return (app.presetStore, app.mappingEngine)
}

struct StartPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Preset"
    static let description = IntentDescription("Starts an InputConfig preset, the way clicking Activate does. A running preset is stopped first.")
    static let openAppWhenRun = false

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (store, engine) = try liveApp()
        guard let p = store.presets.first(where: { $0.id == preset.id }) else { throw PresetIntentError.presetGone }
        guard p.isRunnable else { throw PresetIntentError.notRunnable(p.shownName) }
        ActivityLog.shared.info("Shortcuts", "Start \(p.shownName): asked by Siri or a shortcut")
        MenuBarController.activate(p, store: store, engine: engine, background: true)
        guard store.activePresetId == p.id else {
            return .result(dialog: "\(p.shownName) was not started. It may need a confirmation in InputConfig first.")
        }
        return .result(dialog: startedDialog(p, engine: engine))
    }
}

struct StopPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Preset"
    static let description = IntentDescription("Stops the running InputConfig preset and lets go of everything it holds.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (store, engine) = try liveApp()
        let name = store.presets.first { $0.id == store.activePresetId }?.shownName
        // The restart countdown after a crash would start its preset again
        // seconds later; Stop counts as Not Now there.
        let offered = CrashRecoveryService.shared.restartOffered
        if offered != nil { NotificationCenter.default.post(name: CrashRecoveryService.declineRestartNotification, object: nil) }
        MenuBarController.deactivate(store: store, engine: engine)
        ActivityLog.shared.info("Shortcuts", "Stop: asked by Siri or a shortcut")
        if let name { return .result(dialog: "Stopped \(name).") }
        if let offered { return .result(dialog: "\(offered) will not start again.") }
        return .result(dialog: "No preset was running.")
    }
}

struct TogglePresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Stop Preset"
    static let description = IntentDescription("Starts the preset if it is not running, and stops it if it is.")
    static let openAppWhenRun = false

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start or stop \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (store, engine) = try liveApp()
        guard let p = store.presets.first(where: { $0.id == preset.id }) else { throw PresetIntentError.presetGone }
        if store.activePresetId == p.id {
            MenuBarController.deactivate(store: store, engine: engine)
            ActivityLog.shared.info("Shortcuts", "Stop \(p.shownName): asked by Siri or a shortcut")
            return .result(dialog: "Stopped \(p.shownName).")
        }
        guard p.isRunnable else { throw PresetIntentError.notRunnable(p.shownName) }
        ActivityLog.shared.info("Shortcuts", "Start \(p.shownName): asked by Siri or a shortcut")
        MenuBarController.activate(p, store: store, engine: engine, background: true)
        guard store.activePresetId == p.id else {
            return .result(dialog: "\(p.shownName) was not started. It may need a confirmation in InputConfig first.")
        }
        return .result(dialog: startedDialog(p, engine: engine))
    }
}

struct GetActivePresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Running Preset"
    static let description = IntentDescription("The preset InputConfig is running, if any, for a shortcut to check or say.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PresetEntity?> & ProvidesDialog {
        let (store, engine) = try liveApp()
        guard let p = store.presets.first(where: { $0.id == store.activePresetId }) else {
            return .result(value: nil, dialog: "No preset is running.")
        }
        let entity = PresetEntity(p, store: store)
        if engine.outputsPaused { return .result(value: entity, dialog: "\(p.shownName) is running, with its outputs paused.") }
        if engine.isHeldByAppGate {
            return .result(value: entity, dialog: "\(p.shownName) is running, held back while an app it does not list is in front.")
        }
        if engine.isSuspended { return .result(value: entity, dialog: "\(p.shownName) is running, held back for now.") }
        return .result(value: entity, dialog: "\(p.shownName) is running.")
    }
}

struct PauseOutputsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Outputs"
    static let description = IntentDescription("Pauses the running preset's keys, clicks and pointer without stopping it, or resumes them.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try setOutputsPaused(nil)
    }
}

/// Pauses, never resumes: "Pause InputConfig" said to outputs already paused
/// turned them back on, as the toggle did.
struct PauseOnlyOutputsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Outputs"
    static let description = IntentDescription("Pauses the running preset's keys, clicks and pointer without stopping it.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try setOutputsPaused(true)
    }
}

/// Resumes, never pauses: "Resume InputConfig" paused live outputs.
struct ResumeOutputsIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Outputs"
    static let description = IntentDescription("Resumes the running preset's keys, clicks and pointer.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try setOutputsPaused(false)
    }
}

/// nil toggles. Says the state the outputs are in afterward.
@MainActor
private func setOutputsPaused(_ paused: Bool?) throws -> some IntentResult & ProvidesDialog {
    let (_, engine) = try liveApp()
    guard engine.isRunning else { return .result(dialog: "No preset is running.") }
    let want = paused ?? !engine.outputsPaused
    if engine.outputsPaused != want {
        engine.outputsPaused = want
        ActivityLog.shared.info("Shortcuts", want ? "Outputs paused: asked by Siri or a shortcut" : "Outputs resumed: asked by Siri or a shortcut")
    }
    if engine.outputsPaused { return .result(dialog: "Outputs paused.") }
    if engine.isHeldByAppGate {
        return .result(dialog: "Outputs resumed. They stay held back while an app the preset does not list is in front.")
    }
    if engine.isSuspended { return .result(dialog: "Outputs resumed. They stay held back for now.") }
    return .result(dialog: "Outputs resumed.")
}

struct EmergencyStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Emergency Stop"
    static let description = IntentDescription("Stops everything now: halts the preset and releases every key, button and note InputConfig is holding.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try liveApp()
        EmergencyStopService.shared.stop(reason: .intent)
        return .result(dialog: "Emergency stop. Everything stopped.")
    }
}

/// Siri learns the preset names the phrases take only when the app says
/// they changed: at launch and after the library changes, coalesced so a
/// batch of saves does one update.
@MainActor
enum AppShortcutsRefresh {
    private static var pending: DispatchWorkItem?

    static func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { InputConfigShortcuts.updateAppShortcutParameters() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
}

/// The phrases Siri, Spotlight and Voice Control know without any setup.
/// Each one has to name the app.
struct InputConfigShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartPresetIntent(),
                    phrases: ["Start \(\.$preset) in \(.applicationName)",
                              "Start the \(\.$preset) preset in \(.applicationName)",
                              "Start an \(.applicationName) preset",
                              "Turn on \(\.$preset) in \(.applicationName)",
                              "Switch to \(\.$preset) in \(.applicationName)",
                              "Use \(\.$preset) in \(.applicationName)",
                              "\(.applicationName) start \(\.$preset)"],
                    shortTitle: "Start Preset",
                    systemImageName: "play.fill")
        AppShortcut(intent: StopPresetIntent(),
                    phrases: ["Stop \(.applicationName)",
                              "Stop the \(.applicationName) preset",
                              "Turn off \(.applicationName)"],
                    shortTitle: "Stop Preset",
                    systemImageName: "stop.fill")
        AppShortcut(intent: PauseOnlyOutputsIntent(),
                    phrases: ["Pause \(.applicationName)"],
                    shortTitle: "Pause",
                    systemImageName: "pause.fill")
        AppShortcut(intent: ResumeOutputsIntent(),
                    phrases: ["Resume \(.applicationName)"],
                    shortTitle: "Resume",
                    systemImageName: "play.fill")
        AppShortcut(intent: EmergencyStopIntent(),
                    phrases: ["Emergency stop \(.applicationName)",
                              "\(.applicationName) emergency stop"],
                    shortTitle: "Emergency Stop",
                    systemImageName: "exclamationmark.octagon.fill")
    }
}
