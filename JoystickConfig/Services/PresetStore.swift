import Foundation
import SwiftUI

/// Manages loading, saving, and organizing presets
@MainActor
class PresetStore: ObservableObject {
    @Published var presets: [Preset] = []
    @Published var activePresetId: UUID?

    /// User-defined groups for organizing the sidebar. Stored in a single
    /// `groups.json` file next to the presets. Presets reference a group
    /// by `groupID`; a preset whose `groupID` is nil or unknown shows in
    /// the default "Ungrouped" section.
    @Published var groups: [PresetGroup] = []

    private let presetsDirectory: URL
    private let groupsFile: URL
    private let legacyPresetsDirectory: URL?

    init() {
        // App presets directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("JoystickConfig", isDirectory: true)
        self.presetsDirectory = appDir.appendingPathComponent("presets", isDirectory: true)
        self.groupsFile = appDir.appendingPathComponent("groups.json")

        // Legacy Joystick Mapper presets directory
        let legacyDir = appSupport.appendingPathComponent("Joystick Mapper", isDirectory: true)
            .appendingPathComponent("presets", isDirectory: true)
        self.legacyPresetsDirectory = FileManager.default.fileExists(atPath: legacyDir.path) ? legacyDir : nil

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)

        loadPresets()
        loadGroups()
        loadTrash()
    }

    // MARK: - Groups

    private func loadGroups() {
        guard let data = try? Data(contentsOf: groupsFile),
              let loaded = try? JSONDecoder().decode([PresetGroup].self, from: data) else {
            return
        }
        groups = loaded.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func saveGroups() {
        let snapshot = groups
        Self.ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.groupsFile, options: .atomic)
            }
        }
    }

    /// Create a new group with the given name and optional initial members.
    /// New groups go to the *top* of the list (lowest sortOrder), matching
    /// the "most recently added is most relevant" pattern users expect from
    /// Finder folders. Returns the new group's UUID so callers can act on
    /// it and play the highlight animation in the sidebar.
    @discardableResult
    func createGroup(named name: String, includingPresets ids: [UUID] = []) -> UUID {
        let topOrder = (groups.map(\.sortOrder).min() ?? 1) - 1
        let group = PresetGroup(name: name, sortOrder: topOrder)
        groups.insert(group, at: 0)
        normalizeGroupOrder()
        saveGroups()

        // Move the specified presets into the new group
        for id in ids {
            if let index = presets.firstIndex(where: { $0.id == id }) {
                presets[index].groupID = group.id
                savePresetToDisk(presets[index])
            }
        }
        return group.id
    }

    /// Drag-reorder support for the sidebar's group list. SwiftUI's `.onMove`
    /// hands us source indices and a destination; we mirror that into the
    /// groups array and rewrite `sortOrder` so the new order survives a
    /// restart.
    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        groups.move(fromOffsets: source, toOffset: destination)
        normalizeGroupOrder()
        saveGroups()
    }

    /// Rewrite `sortOrder` to match the current in-memory order, 0...N-1.
    /// Called after any reorder so future loads come back in the right order.
    private func normalizeGroupOrder() {
        for i in groups.indices {
            groups[i].sortOrder = i
        }
    }

    func renameGroup(_ groupID: UUID, to newName: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = newName
        saveGroups()
    }

    /// Delete a group. Presets that referenced it become ungrouped.
    func deleteGroup(_ groupID: UUID) {
        groups.removeAll { $0.id == groupID }
        saveGroups()

        for index in presets.indices where presets[index].groupID == groupID {
            presets[index].groupID = nil
            savePresetToDisk(presets[index])
        }
    }

    func toggleGroupExpanded(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isExpanded.toggle()
        saveGroups()
    }

    /// Move a preset into a group (or remove from group if nil).
    func setPresetGroup(_ presetID: UUID, groupID: UUID?) {
        guard let index = presets.firstIndex(where: { $0.id == presetID }) else { return }
        presets[index].groupID = groupID
        savePresetToDisk(presets[index])
    }

    /// Returns the list of presets that belong to the given group (or
    /// ungrouped presets if groupID is nil). Maintains the sort order of
    /// `presets` so the sidebar stays stable when groups change.
    func presets(in groupID: UUID?) -> [Preset] {
        if let groupID = groupID {
            return presets.filter { $0.groupID == groupID }
        } else {
            // Ungrouped or referencing a group that no longer exists
            let validIDs = Set(groups.map(\.id))
            return presets.filter { p in
                p.groupID == nil || !validIDs.contains(p.groupID!)
            }
        }
    }

    // MARK: - Loading

    func loadPresets() {
        var loaded: [Preset] = []

        // Load native format presets
        if let files = try? FileManager.default.contentsOfDirectory(at: presetsDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let preset = try? JSONDecoder().decode(Preset.self, from: data) {
                    loaded.append(preset)
                }
            }
        }

        // First-launch example seeding is handled by `reseedExamplePresets`
        // (called from ContentView.onAppear), not here. Doing it here too
        // wrote example presets without group IDs because the group-seed
        // step hadn't run yet, which caused everything to land Ungrouped.

        // Always start with nothing active
        for i in loaded.indices {
            loaded[i].isActive = false
        }
        presets = loaded.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Re-seed example presets and (on first install only) the default
    /// groups. Presets are matched by name; groups are seeded behind a
    /// one-shot UserDefaults flag so an App Store update never overwrites a
    /// user's renamed or deleted groups.
    func reseedExamplePresets() {
        let defaults = UserDefaults.standard
        let groupSeedKey = "JoystickConfig.seededExampleGroups.v1"
        let isFirstGroupSeed = !defaults.bool(forKey: groupSeedKey)

        // Step 1: ensure the named groups exist if this is the first launch.
        // Re-seeding presets later can adopt these group IDs.
        if isFirstGroupSeed {
            var sortIndex = 0
            for groupName in ExamplePresets.groupOrder {
                if groups.contains(where: { $0.name == groupName }) {
                    // User somehow already has a group by this exact name;
                    // leave it alone.
                    sortIndex += 1
                    continue
                }
                let group = PresetGroup(name: groupName, sortOrder: sortIndex)
                groups.append(group)
                sortIndex += 1
            }
            saveGroups()
            defaults.set(true, forKey: groupSeedKey)
        }

        // Step 2: seed any missing example preset. Assign its group based on
        // ExamplePresets.groupAssignments + the current group list.
        let existingNames = Set(presets.map { $0.name })
        // Build name -> id map but tolerate duplicates (a user may have two
        // groups with the same name); keep the first occurrence.
        var groupIDsByName: [String: UUID] = [:]
        for group in groups where groupIDsByName[group.name] == nil {
            groupIDsByName[group.name] = group.id
        }

        for example in ExamplePresets.all where !existingNames.contains(example.name) {
            var copy = example
            if let groupName = ExamplePresets.groupAssignments[example.name],
               let groupID = groupIDsByName[groupName] {
                copy.groupID = groupID
            }
            savePreset(copy)
        }
    }

    // MARK: - Saving

    /// Save to disk only (no array update)
    /// Shared serial queue for all disk I/O so JSON encoding and file
    /// writes never block the main thread. Saving a preset with many
    /// bindings can otherwise take 100–200 ms on the main run loop,
    /// which the user feels as a freeze when clicking Save.
    private static let ioQueue = DispatchQueue(label: "com.joystickconfig.preset-io",
                                                qos: .utility)

    private func savePresetToDisk(_ preset: Preset) {
        var mutable = preset
        mutable.modifiedAt = Date()
        let fileURL = presetsDirectory.appendingPathComponent(mutable.filename)
        Self.ioQueue.async {
            if let data = try? JSONEncoder().encode(mutable) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    func savePreset(_ preset: Preset) {
        var mutable = preset
        mutable.modifiedAt = Date()
        let fileURL = presetsDirectory.appendingPathComponent(mutable.filename)

        // Snapshot the prior contents (if any) before overwriting, so the
        // user can revert. Capture mutates only the prior file, not the new
        // one - so this runs before the encode of the new state.
        let priorFile = fileURL
        let snapshotDir = versionsDirectory.appendingPathComponent(mutable.id.uuidString)

        // Update the in-memory model immediately so the UI stays in sync,
        // but push the encode + write to a background queue so the Save
        // button feels instant.
        Self.ioQueue.async {
            // 1. Snapshot the prior file content alongside its modification
            //    timestamp (used as the snapshot filename).
            if let priorData = try? Data(contentsOf: priorFile) {
                try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                let snapName = "\(Int(Date().timeIntervalSince1970)).json"
                let snapURL = snapshotDir.appendingPathComponent(snapName)
                try? priorData.write(to: snapURL, options: .atomic)
                // Prune to the most recent 10 snapshots.
                if let existing = try? FileManager.default.contentsOfDirectory(at: snapshotDir,
                                                                               includingPropertiesForKeys: [.contentModificationDateKey]) {
                    let sorted = existing.sorted {
                        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
                            ?? .distantPast >
                        (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
                            ?? .distantPast
                    }
                    for url in sorted.dropFirst(10) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }

            // 2. Write the new state.
            if let data = try? JSONEncoder().encode(mutable) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        if let index = presets.firstIndex(where: { $0.id == mutable.id }) {
            presets[index] = mutable
        } else {
            presets.insert(mutable, at: 0)
        }
    }

    // MARK: - Version history

    /// Directory holding per-preset snapshots: `versions/<presetID>/<unix>.json`.
    private var versionsDirectory: URL {
        let dir = presetsDirectory.deletingLastPathComponent().appendingPathComponent("versions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One historical snapshot of a preset. The `Preset` value is the parsed
    /// content of the snapshot file; `savedAt` is its file modification date.
    struct PresetVersion: Identifiable {
        var id: URL { fileURL }
        let fileURL: URL
        let savedAt: Date
        let preset: Preset
    }

    /// List the most-recent-first snapshots of a preset's file, newest first.
    func versions(for preset: Preset) -> [PresetVersion] {
        let dir = versionsDirectory.appendingPathComponent(preset.id.uuidString)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        var out: [PresetVersion] = []
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let p = try? JSONDecoder().decode(Preset.self, from: data) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append(PresetVersion(fileURL: url, savedAt: date, preset: p))
        }
        return out.sorted { $0.savedAt > $1.savedAt }
    }

    /// Restore a snapshot: write its content over the current preset file
    /// and swap the in-memory model. The current state of the preset is
    /// itself snapshotted first (via the usual savePreset path) so a revert
    /// is reversible. We preserve the existing preset's UUID / filename so
    /// the sidebar selection and on-disk identity stay stable.
    func revertPreset(_ preset: Preset, to version: PresetVersion) {
        var restored = Preset(
            name: version.preset.name,
            tag: version.preset.tag,
            joysticks: version.preset.joysticks,
            filename: preset.filename,
            isActive: preset.isActive,
            groupID: version.preset.groupID
        )
        // savePreset will set modifiedAt; preserve createdAt from the live
        // preset since the snapshot represented an older save.
        restored.createdAt = preset.createdAt
        // Reassign the live UUID via Codable round-trip (struct is value
        // type, so we serialize+rewrite to put the original id back).
        if let data = try? JSONEncoder().encode(restored),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict["id"] = preset.id.uuidString
            if let patched = try? JSONSerialization.data(withJSONObject: dict),
               let final = try? JSONDecoder().decode(Preset.self, from: patched) {
                savePreset(final)
                return
            }
        }
        // Fallback: save with whatever the snapshot's id was (which will
        // appear as a "new" preset in the sidebar).
        savePreset(restored)
    }

    /// Public URL of the preset's JSON file on disk. Used by the "Open in
    /// Finder" action in PresetDetailView.
    func fileURL(for preset: Preset) -> URL {
        presetsDirectory.appendingPathComponent(preset.filename)
    }

    // MARK: - CRUD

    func createPreset() -> Preset {
        let preset = Preset(name: "New Preset", joysticks: [JoystickMapping(tag: "Add bindings here")])
        savePreset(preset)
        return preset
    }

    /// Soft-deleted preset waiting to be either restored via undo or
    /// expired out of the buffer. The full Preset value is preserved so
    /// restore is a pure value-copy + rewrite of the JSON file.
    struct DeletedPreset: Identifiable {
        let id = UUID()
        let preset: Preset
        let deletedAt: Date
    }

    /// Everything the user has deleted, newest first. Persisted to disk
    /// under `trash/` so deletions survive launches. No TTL - entries stay
    /// until the user restores them or empties the trash explicitly.
    @Published var recentlyDeleted: [DeletedPreset] = []

    /// On-disk directory where deleted presets are parked. Sibling of
    /// `presets/` so the user can find both in the same Application
    /// Support folder.
    private var trashDirectory: URL {
        let dir = presetsDirectory.deletingLastPathComponent()
            .appendingPathComponent("trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func deletePreset(_ preset: Preset) {
        if preset.id == activePresetId {
            deactivateAll()
        }
        presets.removeAll { $0.id == preset.id }

        // Move the on-disk file from presets/ to trash/ instead of
        // deleting it. Restoring is then a simple move-back operation.
        let source = presetsDirectory.appendingPathComponent(preset.filename)
        let dest = trashDirectory.appendingPathComponent(preset.filename)
        // If the destination already exists (re-deleted preset), nuke the
        // old copy first so the move can succeed.
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: source, to: dest)

        recentlyDeleted.insert(DeletedPreset(preset: preset, deletedAt: Date()), at: 0)
    }

    /// Re-create a previously-deleted preset. Moves the JSON back from
    /// trash/ to presets/ and drops the entry from `recentlyDeleted`.
    @discardableResult
    func restoreDeleted(_ entry: DeletedPreset) -> Bool {
        guard recentlyDeleted.contains(where: { $0.id == entry.id }) else { return false }
        recentlyDeleted.removeAll { $0.id == entry.id }

        let trashed = trashDirectory.appendingPathComponent(entry.preset.filename)
        let restored = presetsDirectory.appendingPathComponent(entry.preset.filename)
        if FileManager.default.fileExists(atPath: trashed.path) {
            try? FileManager.default.removeItem(at: restored)
            try? FileManager.default.moveItem(at: trashed, to: restored)
        }

        // savePreset re-inserts into in-memory `presets` (no-op file
        // write is fine - the file already exists at the target).
        savePreset(entry.preset)
        return true
    }

    /// Permanently delete a single trash entry. Removes the on-disk file
    /// and the in-memory record. Use sparingly - the user can no longer
    /// restore after this.
    func permanentlyDelete(_ entry: DeletedPreset) {
        recentlyDeleted.removeAll { $0.id == entry.id }
        let url = trashDirectory.appendingPathComponent(entry.preset.filename)
        try? FileManager.default.removeItem(at: url)
    }

    /// Permanently delete everything in the trash. The on-disk trash
    /// folder is wiped along with the in-memory list.
    func emptyTrash() {
        recentlyDeleted.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: trashDirectory,
                                                                     includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Convenience for "Cmd-Z-style" undo after the most recent delete.
    @discardableResult
    func restoreMostRecentlyDeleted() -> Preset? {
        guard let first = recentlyDeleted.first else { return nil }
        if restoreDeleted(first) {
            return first.preset
        }
        return nil
    }

    /// Re-hydrate `recentlyDeleted` from on-disk trash on launch so the
    /// list survives app restarts. Called once from init.
    func loadTrash() {
        let dir = trashDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        var loaded: [DeletedPreset] = []
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let preset = try? JSONDecoder().decode(Preset.self, from: data) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            loaded.append(DeletedPreset(preset: preset, deletedAt: date))
        }
        recentlyDeleted = loaded.sorted { $0.deletedAt > $1.deletedAt }
    }

    func duplicatePreset(_ preset: Preset) -> Preset {
        var clone = preset
        clone = Preset(
            name: "\(preset.name) (Copy)",
            tag: preset.tag,
            joysticks: preset.joysticks,
            filename: Preset.generateFilename(),
            isActive: false
        )
        savePreset(clone)
        return clone
    }

    // MARK: - Reordering

    func movePresets(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Activation

    func activatePreset(_ preset: Preset) {
        deactivateAll()
        activePresetId = preset.id
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index].isActive = true
        }
    }

    func deactivateAll() {
        activePresetId = nil
        for i in presets.indices {
            presets[i].isActive = false
        }
    }

    func togglePreset(_ preset: Preset) {
        if preset.isActive {
            deactivateAll()
        } else {
            activatePreset(preset)
        }
    }

    // MARK: - Import / Export

    func importLegacyPreset(from url: URL) -> Preset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard var preset = Preset.fromLegacyJSON(data, filename: Preset.generateFilename()) else { return nil }
        preset.filename = Preset.generateFilename()
        savePreset(preset)
        return preset
    }

    func importLegacyPresetsFromOriginalApp() -> Int {
        guard let legacyDir = legacyPresetsDirectory else { return 0 }
        guard let files = try? FileManager.default.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) else { return 0 }

        var count = 0
        for file in files where file.pathExtension == "txt" {
            if importLegacyPreset(from: file) != nil {
                count += 1
            }
        }
        return count
    }

    func exportPresetAsLegacy(_ preset: Preset) -> Data? {
        return preset.toLegacyJSON()
    }

    func exportPresetToFile(_ preset: Preset, to url: URL) {
        if let data = preset.toLegacyJSON() {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Conversion

    func convertPreset(_ preset: Preset, from source: ControllerType, to destination: ControllerType) -> Preset {
        var converted = ControllerType.convert(preset: preset, from: source, to: destination)
        converted.filename = Preset.generateFilename()
        savePreset(converted)
        return converted
    }
}
