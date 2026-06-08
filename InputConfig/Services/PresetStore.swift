import Foundation
import SwiftUI

/// Manages loading, saving, and organizing presets
@MainActor
class PresetStore: ObservableObject {
    @Published var presets: [Preset] = []
    @Published var activePresetId: UUID?

    /// The most recently activated preset, persisted across launches so the
    /// global hotkey can re-activate "the last preset" even after a relaunch.
    /// Updated by `activatePreset`.
    var lastActivatedPresetId: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: "InputConfig.lastActivatedPresetId")
            else { return nil }
            return UUID(uuidString: s)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString,
                                      forKey: "InputConfig.lastActivatedPresetId")
        }
    }

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
        let appDir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
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
        // groups.json is tiny, so write it synchronously: a deferred write was
        // getting lost when folders were created during first-launch seeding
        // and the app was relaunched before the async write flushed, leaving
        // the seed flag set but no groups file (a permanent "no folders"
        // desync). Also make sure the parent directory exists so the write
        // can't silently fail on a brand-new install.
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? FileManager.default.createDirectory(
            at: groupsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: groupsFile, options: .atomic)
    }

    /// Create a new group with the given name and optional initial members.
    /// New groups go to the *top* of the list (lowest sortOrder), matching
    /// the "most recently added is most relevant" pattern users expect from
    /// Finder folders. Returns the new group's UUID so callers can act on
    /// it and play the highlight animation in the sidebar.
    @discardableResult
    func createGroup(named name: String, includingPresets ids: [UUID] = [],
                     parentID: UUID? = nil) -> UUID {
        // New folder sorts to the top of its own sibling set. sortOrder only
        // ever orders siblings (every query filters by parent first), so a
        // sibling-relative min-1 is safe and avoids renumbering the rest.
        let minOrder = groups.filter { $0.parentID == parentID }.map(\.sortOrder).min() ?? 1
        let group = PresetGroup(name: name, sortOrder: minOrder - 1, parentID: parentID)
        groups.append(group)
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

    /// Re-insert a group from a backup envelope, preserving its UUID so
    /// presets that reference `groupID` keep working after restore. Used
    /// by Settings > Restore Backup; differs from `createGroup` (which
    /// always mints a fresh UUID). If the same UUID already exists
    /// locally we skip rather than overwriting - the user's current
    /// name / color / order wins, since they're the one looking at
    /// this Mac right now.
    func upsertGroup(_ group: PresetGroup) {
        if groups.contains(where: { $0.id == group.id }) { return }
        groups.append(group)
        normalizeGroupOrder()
        saveGroups()
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
        // Promote any child folders up to the deleted folder's parent so they
        // aren't orphaned (and stay visible) rather than vanishing with it.
        let removedParent = groups.first(where: { $0.id == groupID })?.parentID
        groups.removeAll { $0.id == groupID }
        for index in groups.indices where groups[index].parentID == groupID {
            groups[index].parentID = removedParent
        }
        saveGroups()

        // Presets that lived directly in the deleted folder become ungrouped.
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

    /// Set a folder's expanded state explicitly (unlike toggle). Used when
    /// adding a subfolder or moving a folder so the destination opens to
    /// reveal the change.
    func setGroupExpanded(_ groupID: UUID, _ expanded: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if groups[index].isExpanded != expanded {
            groups[index].isExpanded = expanded
            saveGroups()
        }
    }

    /// Set the user-pickable tint for a folder. Pass nil to clear the
    /// tint (renders as neutral). The string must be a name from
    /// `PresetGroup.colorOptions` so the lookup in the sidebar stays
    /// stable across app launches.
    func setGroupColor(_ groupID: UUID, color: String?) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].color = color
        saveGroups()
    }

    /// Apply the ship-default tint to this folder (looked up by name in
    /// `ExamplePresets.groupDefaultColors`). No-op for user-created
    /// folders whose name doesn't match a built-in group.
    func applyDefaultGroupColor(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let defaultColor = ExamplePresets.groupDefaultColors[groups[index].name]
        groups[index].color = defaultColor
        saveGroups()
    }

    // MARK: - Nested folders

    /// Top-level folders (no parent), in display order.
    var topLevelGroups: [PresetGroup] {
        groups.filter { $0.parentID == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Direct child folders of the given folder, in display order.
    func subgroups(of parentID: UUID) -> [PresetGroup] {
        groups.filter { $0.parentID == parentID }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// True if `candidate` is `ancestor` itself or nested anywhere beneath it.
    /// Used to block moves that would create a cycle.
    func isGroup(_ candidate: UUID, descendantOfOrEqualTo ancestor: UUID) -> Bool {
        var cursor: UUID? = candidate
        var hops = 0
        while let c = cursor, hops < 256 {
            if c == ancestor { return true }
            cursor = groups.first(where: { $0.id == c })?.parentID
            hops += 1
        }
        return false
    }

    /// Re-parent a folder (nil = make it top-level). No-ops if it would create
    /// a cycle (moving a folder into itself or one of its own descendants).
    func setGroupParent(_ groupID: UUID, parentID: UUID?) {
        if let parentID {
            if parentID == groupID { return }
            if isGroup(parentID, descendantOfOrEqualTo: groupID) { return }
        }
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].parentID = parentID
        // Drop it at the top of its new sibling set.
        let minOrder = groups.filter { $0.parentID == parentID && $0.id != groupID }
            .map(\.sortOrder).min() ?? 1
        groups[index].sortOrder = minOrder - 1
        saveGroups()
    }

    /// Drag-reorder for the top-level folder list. Reassigns sortOrder only for
    /// top-level folders; nested folders keep their own ordering.
    func moveTopLevelGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        var top = topLevelGroups
        top.move(fromOffsets: source, toOffset: destination)
        for (i, g) in top.enumerated() {
            if let idx = groups.firstIndex(where: { $0.id == g.id }) {
                groups[idx].sortOrder = i
            }
        }
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
        let groupSeedKey = "InputConfig.seededExampleGroups.v1"
        let isFirstGroupSeed = !defaults.bool(forKey: groupSeedKey)
        // Self-heal: the seed flag lives in UserDefaults while the folders live
        // in groups.json, so the two can fall out of sync (flag set, file
        // missing) and leave the app permanently folderless. Detect that by
        // actual state, not a one-shot flag: if the ship folders are gone but
        // built-in presets that belong in folders are still present, then
        // groups.json was lost, so recreate the ship folders. Step 3 below then
        // re-files the presets into them. A user who deleted every folder and
        // its built-in presets is left alone (nothing to re-file).
        let shipPresetsPresent = presets.contains {
            ExamplePresets.groupAssignments[$0.name] != nil
        }
        let needsGroupRepair = groups.isEmpty && shipPresetsPresent

        // Step 1: ensure the named ship groups exist on first launch (or on the
        // one-time repair). Re-seeding presets below adopts these group IDs.
        if isFirstGroupSeed || needsGroupRepair {
            var sortIndex = (groups.map(\.sortOrder).max().map { $0 + 1 }) ?? 0
            for groupName in ExamplePresets.groupOrder {
                if groups.contains(where: { $0.name == groupName }) {
                    // Already have a folder by this exact name; leave it alone.
                    continue
                }
                // Resolve the parent folder by name. groupOrder lists parents
                // before their children, so the parent is already in `groups`.
                let parentID: UUID? = ExamplePresets.groupParents[groupName]
                    .flatMap { parentName in groups.first(where: { $0.name == parentName })?.id }
                let group = PresetGroup(
                    name: groupName,
                    sortOrder: sortIndex,
                    color: ExamplePresets.groupDefaultColors[groupName],
                    parentID: parentID
                )
                groups.append(group)
                sortIndex += 1
            }
            groups.sort { $0.sortOrder < $1.sortOrder }
            saveGroups()
            defaults.set(true, forKey: groupSeedKey)
        }

        // Step 1b: on initial install, backfill nil colors. On the
        // one-shot "v2" pass, OVERWRITE colors for built-in groups so
        // existing installs pick up the curated palette (orange / green
        // / red / teal). The version bump lets us re-curate the
        // defaults without trampling user customisations on every launch:
        // future launches see the v2 key set and only backfill nils
        // again. User-renamed groups are untouched because the lookup
        // matches by group NAME.
        let colorVersionKey = "InputConfig.appliedDefaultGroupColors.v2"
        let didApplyV2 = defaults.bool(forKey: colorVersionKey)
        var didColorBackfill = false
        for index in groups.indices {
            guard let defaultColor = ExamplePresets.groupDefaultColors[groups[index].name] else {
                continue
            }
            if !didApplyV2 {
                // First time on this version: apply the new curated tint
                // to every built-in group, overwriting whatever was there.
                if groups[index].color != defaultColor {
                    groups[index].color = defaultColor
                    didColorBackfill = true
                }
            } else if groups[index].color == nil {
                // Subsequent launches: only fill nils so we never
                // overwrite a colour the user picked from the menu.
                groups[index].color = defaultColor
                didColorBackfill = true
            }
        }
        if didColorBackfill { saveGroups() }
        if !didApplyV2 { defaults.set(true, forKey: colorVersionKey) }

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

        // Step 3 (self-heal): make sure every built-in example preset that
        // belongs in a ship folder is actually in it. This only fixes presets
        // that are currently unassigned or point at a group that no longer
        // exists (a dangling id left over when groups.json was lost and
        // rebuilt with fresh ids). A preset the user moved into a different,
        // still-valid folder is left exactly where they put it.
        let validGroupIDs = Set(groups.map { $0.id })
        for index in presets.indices {
            guard let groupName = ExamplePresets.groupAssignments[presets[index].name],
                  let groupID = groupIDsByName[groupName] else { continue }
            let current = presets[index].groupID
            if current == nil || !validGroupIDs.contains(current!) {
                presets[index].groupID = groupID
                savePresetToDisk(presets[index])
            }
        }
    }

    // MARK: - Saving

    /// Save to disk only (no array update)
    /// Shared serial queue for all disk I/O so JSON encoding and file
    /// writes never block the main thread. Saving a preset with many
    /// bindings can otherwise take 100-200 ms on the main run loop,
    /// which the user feels as a freeze when clicking Save.
    private static let ioQueue = DispatchQueue(label: "com.inputconfig.preset-io",
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

    /// Permanent delete: skip the trash + Recently Deleted buffer.
    /// Used when the user cancels out of the editor on a newly created
    /// draft - we don't want a string of empty "New Preset" drafts
    /// piling up in the undo history just because the user clicked
    /// "New" and then changed their mind.
    func hardDeletePreset(_ preset: Preset) {
        if preset.id == activePresetId {
            deactivateAll()
        }
        presets.removeAll { $0.id == preset.id }
        let source = presetsDirectory.appendingPathComponent(preset.filename)
        try? FileManager.default.removeItem(at: source)
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

    /// Re-insert a previously-trashed preset from a backup envelope.
    /// Writes the JSON to trash/ on disk and pushes it into the
    /// in-memory `recentlyDeleted` list so the trash survives a
    /// machine migration. Skips when the preset ID is already in the
    /// trash (idempotent backup restore).
    func restoreTrashFromBackup(preset: Preset, deletedAt: Date) {
        if recentlyDeleted.contains(where: { $0.preset.id == preset.id }) { return }
        let target = trashDirectory.appendingPathComponent(preset.filename)
        if let data = try? JSONEncoder().encode(preset) {
            try? data.write(to: target)
        }
        recentlyDeleted.insert(DeletedPreset(preset: preset, deletedAt: deletedAt), at: 0)
    }

    /// Codable snapshot of one trash entry for backup export / restore.
    /// `DeletedPreset.id` is a transient UUID that's re-minted on every
    /// load, so we expose `preset` + `deletedAt` only.
    struct TrashSnapshot: Codable {
        let preset: Preset
        let deletedAt: Date
    }

    /// Export every trash entry for a backup envelope. Empty array if
    /// the trash is empty - the backup file stays tidy.
    func snapshotTrashForBackup() -> [TrashSnapshot] {
        recentlyDeleted.map { TrashSnapshot(preset: $0.preset, deletedAt: $0.deletedAt) }
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
        lastActivatedPresetId = preset.id
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index].isActive = true
        }
        // Persist active preset to the recovery sentinel so a crash
        // here doesn't lose the user's place.
        Task { @MainActor in
            CrashRecoveryService.shared.recordActivePreset(preset.id)
        }
    }

    func deactivateAll() {
        activePresetId = nil
        for i in presets.indices {
            presets[i].isActive = false
        }
        Task { @MainActor in
            CrashRecoveryService.shared.recordActivePreset(nil)
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

    /// Result of an import attempt. Distinguishes file IO errors from
    /// parse errors from "valid JSON but wrong schema" so the UI can
    /// give the user a specific message instead of a silent no-op.
    enum ImportResult {
        case success(Preset)
        case fileUnreadable(String)
        case parseError(String)
        case schemaError(String)
    }

    /// One row in the import review sheet. Either a parsed preset
    /// (which the user can rename before confirming) or a parse error
    /// (which the sheet shows verbatim). The URL is kept for re-read /
    /// "Show in Finder" actions.
    struct ImportPreview: Identifiable {
        let id = UUID()
        let url: URL
        let filename: String
        /// Editable name shown in the review sheet. Pre-populated from
        /// the parsed preset's name, or the filename minus extension
        /// for files we couldn't parse.
        var nameDraft: String
        /// Parsed preset value. Mutated when the user types into the
        /// rename field. nil when the file failed to parse.
        var preset: Preset?
        /// Specific failure message when preset is nil.
        var errorMessage: String?
        /// Whether this is a parseable file the user accepted.
        var isImportable: Bool { preset != nil }
    }

    /// Sheet-driven state: a non-empty array opens the review sheet.
    /// Reset to empty on dismiss / cancel / completion.
    @Published var importReviewQueue: [ImportPreview] = []

    /// Reports the last attempted import result so the SwiftUI sheet
    /// can render a toast / alert. Reset when the user dismisses.
    @Published var lastImportResult: ImportResult?
    /// Mirror "did anything fail in the last batch?" so a multi-file
    /// import can show one summary alert instead of N modal dialogs.
    @Published var lastImportFailures: [(filename: String, reason: String)] = []

    /// Import a JSON or legacy text file. Tries (1) the modern Preset
    /// codable shape, (2) the legacy `Preset.fromLegacyJSON` path.
    /// Returns the imported preset or sets `lastImportResult` to a
    /// descriptive error case the UI can surface.
    @discardableResult
    func importLegacyPreset(from url: URL) -> Preset? {
        let filename = url.lastPathComponent
        // Sandbox: security-scoped URL from the user-picker. Must
        // claim the scope before reading; balance with stop in defer.
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else {
            let msg = "Couldn't read file '\(filename)'. Permission denied or file missing."
            lastImportResult = .fileUnreadable(msg)
            lastImportFailures.append((filename, msg))
            return nil
        }
        // First try the modern Preset codable shape so we get a
        // specific Swift error if the JSON is structurally wrong.
        do {
            var preset = try JSONDecoder().decode(Preset.self, from: data)
            preset.filename = Preset.generateFilename()
            savePreset(preset)
            lastImportResult = .success(preset)
            return preset
        } catch let decodeError {
            // Modern decode failed - try the legacy path before giving
            // up. fromLegacyJSON returns nil rather than throwing, so
            // we surface the decode error if THAT fails too.
            if var legacy = Preset.fromLegacyJSON(data, filename: Preset.generateFilename()) {
                legacy.filename = Preset.generateFilename()
                savePreset(legacy)
                lastImportResult = .success(legacy)
                return legacy
            }
            // Determine whether this was a JSON syntax error (invalid
            // bytes) or a schema error (valid JSON, wrong shape) so
            // the message can be specific.
            let isSyntaxError: Bool
            if let de = decodeError as? DecodingError {
                if case .dataCorrupted = de { isSyntaxError = true } else { isSyntaxError = false }
            } else {
                isSyntaxError = false
            }
            let reason: String
            if isSyntaxError {
                reason = "'\(filename)' is not valid JSON. Open it in a text editor and check for missing braces, quotes, or commas."
                lastImportResult = .parseError(reason)
            } else {
                reason = "'\(filename)' is JSON but doesn't match the preset schema (\(describe(decodeError))). It may be from an unsupported app version."
                lastImportResult = .schemaError(reason)
            }
            lastImportFailures.append((filename, reason))
            return nil
        }
    }

    /// Pull the human-readable description out of a DecodingError so
    /// the import alert can say exactly which field failed (e.g.
    /// "joysticks: expected array, got number").
    private func describe(_ error: Error) -> String {
        guard let de = error as? DecodingError else { return error.localizedDescription }
        switch de {
        case .typeMismatch(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? ctx.debugDescription
                                 : "\(path): \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path): value not found"
        case .keyNotFound(let key, _):
            return "missing field '\(key.stringValue)'"
        case .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return de.localizedDescription
        }
    }

    /// Clears the buffered import error so the alert can be dismissed.
    func acknowledgeImportFailures() {
        lastImportResult = nil
        lastImportFailures.removeAll()
    }

    /// Read each URL and produce a preview (parsed preset OR error
    /// message). Does NOT touch the on-disk preset list - the user
    /// has to confirm via `commitImportPreviews(_:)` first. Drives the
    /// ImportReviewSheet.
    ///
    /// SwiftUI's fileImporter hands us security-scoped URLs. The app
    /// is sandboxed, so reading them with plain `Data(contentsOf:)`
    /// silently fails with "permission denied" unless we claim the
    /// security scope first. Pair every `startAccessing` with a
    /// matched `stop`.
    func previewImports(from urls: [URL]) {
        var previews: [ImportPreview] = []
        for url in urls {
            let filename = url.lastPathComponent
            let baseName = (filename as NSString).deletingPathExtension
            let scopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if scopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                previews.append(ImportPreview(
                    url: url,
                    filename: filename,
                    nameDraft: baseName,
                    preset: nil,
                    errorMessage: "Couldn't read file: \(error.localizedDescription)"
                ))
                continue
            }
            // Try modern Preset codable shape first.
            do {
                var preset = try JSONDecoder().decode(Preset.self, from: data)
                preset.filename = Preset.generateFilename()
                previews.append(ImportPreview(
                    url: url,
                    filename: filename,
                    nameDraft: preset.name.isEmpty ? baseName : preset.name,
                    preset: preset,
                    errorMessage: nil
                ))
                continue
            } catch let decodeError {
                // Try legacy text-based preset format before giving up.
                if var legacy = Preset.fromLegacyJSON(data, filename: Preset.generateFilename()) {
                    legacy.filename = Preset.generateFilename()
                    previews.append(ImportPreview(
                        url: url,
                        filename: filename,
                        nameDraft: legacy.name.isEmpty ? baseName : legacy.name,
                        preset: legacy,
                        errorMessage: nil
                    ))
                    continue
                }
                // Build the human-readable explanation.
                let isSyntaxError: Bool
                if let de = decodeError as? DecodingError,
                   case .dataCorrupted = de {
                    isSyntaxError = true
                } else {
                    isSyntaxError = false
                }
                let msg: String
                if isSyntaxError {
                    msg = "Invalid JSON. Open the file in a text editor and check for missing braces, quotes, or commas."
                } else {
                    msg = "JSON doesn't match the preset schema (\(describe(decodeError)). The file may be from an unsupported app version."
                }
                previews.append(ImportPreview(
                    url: url,
                    filename: filename,
                    nameDraft: baseName,
                    preset: nil,
                    errorMessage: msg
                ))
            }
        }
        importReviewQueue = previews
    }

    /// Commit the user's reviewed selections. Each preview that's
    /// .isImportable and has a (possibly renamed) draft gets saved
    /// to the on-disk presets directory. Returns the number of presets
    /// actually saved.
    @discardableResult
    func commitImportPreviews(_ previews: [ImportPreview]) -> Int {
        var saved = 0
        for preview in previews {
            guard var preset = preview.preset else { continue }
            let trimmed = preview.nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { preset.name = trimmed }
            preset.filename = Preset.generateFilename()
            savePreset(preset)
            saved += 1
        }
        importReviewQueue = []
        return saved
    }

    /// Discard the pending review without saving anything.
    func cancelImportReview() {
        importReviewQueue = []
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
