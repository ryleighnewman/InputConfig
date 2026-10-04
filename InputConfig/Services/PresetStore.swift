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

    // MARK: - Favorites

    static let favoritesKey = "InputConfig.favoritePresets"
    static let favoritesOnlyKey = "InputConfig.favoritesOnly"

    /// Starred presets, by id. Kept in the app's preferences rather than in
    /// the preset files, so exporting or sharing a preset never carries
    /// someone's favorites into another library.
    @Published private(set) var favoriteIDs: Set<UUID> = Set(
        (UserDefaults.standard.stringArray(forKey: PresetStore.favoritesKey) ?? []).compactMap(UUID.init)
    )

    /// Show only the starred presets, in the sidebar and the menu bar list.
    @Published var showFavoritesOnly: Bool = UserDefaults.standard.bool(forKey: PresetStore.favoritesOnlyKey) {
        didSet { UserDefaults.standard.set(showFavoritesOnly, forKey: Self.favoritesOnlyKey) }
    }

    func isFavorite(_ preset: Preset) -> Bool { favoriteIDs.contains(preset.id) }

    /// Re-read the stars and the favorites filter from preferences, after a
    /// restore wrote them there; otherwise the next star click would write
    /// the old in-memory set over the restored one.
    func reloadFavoritesFromDefaults() {
        let d = UserDefaults.standard
        favoriteIDs = Set((d.stringArray(forKey: Self.favoritesKey) ?? []).compactMap(UUID.init))
        showFavoritesOnly = d.bool(forKey: Self.favoritesOnlyKey) && !favoriteIDs.isEmpty
    }

    /// Stars of presets deleted for good.
    private func forgetStars(_ ids: [UUID]) {
        let live = Set(presets.map(\.id))
        let gone = Set(ids).subtracting(live)
        guard !favoriteIDs.isDisjoint(with: gone) else { return }
        favoriteIDs.subtract(gone)
        UserDefaults.standard.set(favoriteIDs.map(\.uuidString).sorted(), forKey: Self.favoritesKey)
        if favoriteIDs.isEmpty { showFavoritesOnly = false }
    }

    func toggleFavorite(_ preset: Preset) {
        if favoriteIDs.contains(preset.id) { favoriteIDs.remove(preset.id) } else { favoriteIDs.insert(preset.id) }
        UserDefaults.standard.set(favoriteIDs.map(\.uuidString).sorted(), forKey: Self.favoritesKey)
        // With the filter on and the last star removed, the list would be
        // empty with no way back to the rest; turn the filter off.
        if favoriteIDs.isEmpty { showFavoritesOnly = false }
    }

    /// The starred presets that still exist, by name.
    var favoritePresets: [Preset] {
        presets.filter { favoriteIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private let presetsDirectory: URL
    private let groupsFile: URL

    init() {
        // App presets directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("InputConfig", isDirectory: true)
        self.presetsDirectory = appDir.appendingPathComponent("presets", isDirectory: true)
        self.groupsFile = appDir.appendingPathComponent("groups.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)

        loadPresets()
        loadGroups()
        loadTrash()
    }

    // MARK: - Groups

    /// The folders file was missing or unreadable at launch (not the user
    /// deleting every folder, which leaves an empty file).
    private var groupsFileLost = false

    private func loadGroups() {
        guard let data = try? Data(contentsOf: groupsFile) else {
            groupsFileLost = true
            return
        }
        var loaded: [PresetGroup]
        if let all = try? JSONDecoder().decode([PresetGroup].self, from: data) {
            loaded = all
        } else {
            // Unreadable as a whole: keep every folder that still reads, and
            // move the file aside before anything writes over it. Before, the
            // next save replaced it and every folder was gone.
            loaded = []
            if let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                for item in list {
                    if let itemData = try? JSONSerialization.data(withJSONObject: item),
                       let group = try? JSONDecoder().decode(PresetGroup.self, from: itemData) {
                        loaded.append(group)
                    }
                }
            }
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = groupsFile.deletingLastPathComponent().appendingPathComponent("groups.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: groupsFile, to: aside)
            ActivityLog.shared.error("Presets", "The folders file could not be read. \(loaded.count) folder\(loaded.count == 1 ? "" : "s") recovered; the original is kept as \(aside.lastPathComponent)")
            if !loaded.isEmpty {
                groups = loaded.sorted { $0.sortOrder < $1.sortOrder }
                saveGroups()
            } else {
                groupsFileLost = true
            }
        }
        groups = loaded.sorted { $0.sortOrder < $1.sortOrder }
        if repairGroups() { saveGroups() }
        // One-time: installs from before the flag existed mark the shipped
        // folders by their original names. A folder the user has since
        // renamed simply stays under My Presets, which is where they put it.
        let flaggedKey = "InputConfig.groups.builtInFlagged"
        if !UserDefaults.standard.bool(forKey: flaggedKey) {
            let shipped = Set(ExamplePresets.groupOrder)
            for i in groups.indices where shipped.contains(groups[i].name) {
                groups[i].isBuiltIn = true
            }
            UserDefaults.standard.set(true, forKey: flaggedKey)
            saveGroups()
        }
    }

    /// Folders the sidebar can always reach: one entry per id (a repeated
    /// id crashed the sidebar's list), and a folder whose parent is missing
    /// or whose parents loop is moved to the top level. Before, such a
    /// folder and every preset in it were on disk and nowhere on screen.
    /// Returns whether anything changed.
    @discardableResult
    private func repairGroups() -> Bool {
        var changed = false
        var seen = Set<UUID>()
        let unique = groups.filter { seen.insert($0.id).inserted }
        if unique.count != groups.count { groups = unique; changed = true }
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        for i in groups.indices {
            var visited: Set<UUID> = [groups[i].id]
            var parent = groups[i].parentID
            var broken = false
            while let p = parent {
                guard let next = byID[p], visited.insert(p).inserted else { broken = true; break }
                parent = next.parentID
            }
            if broken {
                groups[i].parentID = nil
                changed = true
            }
        }
        if changed {
            ActivityLog.shared.info("Presets", "Folders with a missing or looping parent were moved to the top level")
        }
        return changed
    }

    private func saveGroups() {
        // groups.json is tiny, so write it synchronously: a deferred write was
        // getting lost when folders were created during first-launch seeding
        // and the app was relaunched before the async write flushed, leaving
        // the seed flag set but no groups file (a permanent "no folders"
        // desync). Also make sure the parent directory exists so the write
        // can't silently fail on a brand-new install.
        try? FileManager.default.createDirectory(
            at: groupsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        Self.write(try? JSONEncoder().encode(groups), to: groupsFile, what: "your folders")
    }

    /// Write a file and say so in the activity log when it fails. A failed
    /// write used to be silent: the app showed the edit saved and it was
    /// gone on the next launch.
    nonisolated private static func write(_ data: Data?, to url: URL, what: String) {
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            failedLock.lock(); failedWrites[url] = nil; failedLock.unlock()
        } catch {
            let message = "Could not save \(what): \(error.localizedDescription)"
            DispatchQueue.main.async { ActivityLog.shared.error("Presets", message) }
            // Kept and tried again, newest data first: a write that failed
            // on a full disk looked saved and was gone at the next launch.
            guard let data else { return }
            failedLock.lock()
            let first = failedWrites.isEmpty
            failedWrites[url] = (data, what)
            failedLock.unlock()
            if first { scheduleRetry() }
            // Through the run loop, not the main queue: a modal alert run
            // inside a main-queue block holds the queue, so the Emergency
            // Stop shortcut and timed key and click releases wait behind it
            // (the same fix as the quit and crash-restore alerts).
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { warnSaveFailed(what) } }
        }
    }

    nonisolated(unsafe) private static var failedWrites: [URL: (data: Data, what: String)] = [:]
    nonisolated private static let failedLock = NSLock()
    @MainActor private static var warnedSaveFailed = false

    /// Tries the failed writes again every 30 seconds until they all land.
    nonisolated private static func scheduleRetry() {
        ioQueue.asyncAfter(deadline: .now() + 30) {
            failedLock.lock()
            let pending = failedWrites
            failedLock.unlock()
            guard !pending.isEmpty else { return }
            var stillFailing = false
            for (url, entry) in pending {
                // Only while this is still the newest data for the file: a
                // later save that landed, or a delete, drops the entry, and
                // writing it then put back older data or a deleted preset.
                // Checked and written under the lock so neither can slip in.
                failedLock.lock()
                guard failedWrites[url]?.data == entry.data else { failedLock.unlock(); continue }
                let landed = (try? entry.data.write(to: url, options: .atomic)) != nil
                if landed { failedWrites[url] = nil }
                failedLock.unlock()
                if landed {
                    DispatchQueue.main.async { ActivityLog.shared.info("Presets", "Saved \(entry.what) on a later try") }
                } else {
                    stillFailing = true
                }
            }
            if stillFailing { scheduleRetry() }
        }
    }

    /// Once a session: the Mac could not save, the app keeps trying.
    @MainActor private static func warnSaveFailed(_ what: String) {
        guard !warnedSaveFailed else { return }
        warnedSaveFailed = true
        let alert = NSAlert()
        alert.messageText = "InputConfig Could Not Save"
        alert.informativeText = "\(what.prefix(1).uppercased() + what.dropFirst()) could not be saved, usually because the disk is full. InputConfig keeps your changes and tries again every 30 seconds; free some space and they are saved by themselves."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        // Into sortOrder order first (stable), so renumbering from array
        // position keeps the order the sidebar shows: a folder made this
        // session sorts first but sat last in the array, and jumped to the
        // bottom when a backup restore added a folder.
        groups = groups.enumerated()
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)
        groups.append(group)
        normalizeGroupOrder()
        saveGroups()
    }

    /// Drag-reorder support for the sidebar's group list. SwiftUI's `.onMove`
    /// hands us source indices and a destination; we mirror that into the
    /// groups array and rewrite `sortOrder` so the new order survives a
    /// restart.
    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = IndexSet(source.filter { $0 >= 0 && $0 < groups.count })
        guard !valid.isEmpty else { return }
        groups.move(fromOffsets: valid, toOffset: min(max(destination, 0), groups.count))
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

    /// The folder and every folder nested in it.
    private func groupSubtree(_ root: PresetGroup) -> [PresetGroup] {
        var subtree = [root]
        var queue = [root.id]
        while let parent = queue.popLast() {
            for child in groups where child.parentID == parent {
                subtree.append(child)
                queue.append(child.id)
            }
        }
        return subtree
    }

    /// True when the running preset sits in this folder or one inside it,
    /// so deleting the folder has to stop the engine first.
    func folderHoldsActivePreset(_ groupID: UUID) -> Bool {
        guard let root = groups.first(where: { $0.id == groupID }), let active = activePresetId else { return false }
        let ids = Set(groupSubtree(root).map(\.id))
        return presets.contains { $0.id == active && ($0.groupID.map(ids.contains) ?? false) }
    }

    /// Delete a folder into the trash: the folder, every folder inside it,
    /// and every preset in any of them go together as one trash entry, so
    /// Put Back restores the whole thing where it was.
    func deleteGroup(_ groupID: UUID) {
        guard let root = groups.first(where: { $0.id == groupID }) else { return }
        let subtree = groupSubtree(root)
        let ids = Set(subtree.map(\.id))
        // Stored as not running (see deletePreset).
        let inside = presets.filter { $0.groupID.map(ids.contains) ?? false }
            .map { preset -> Preset in var p = preset; p.isActive = false; return p }
        if inside.contains(where: { $0.id == activePresetId }) {
            deactivateAll()
        }
        // The trash copy is written and confirmed on disk BEFORE any preset
        // file is removed. The old order deleted first and wrote the undo
        // envelope after, with the write itself allowed to fail quietly, so
        // a full disk or a bad encode meant every preset in the folder was
        // gone with nothing to put back. If the copy cannot be written the
        // folder stays where it is and the user is told.
        let entry = DeletedFolder(id: root.id, name: root.name, deletedAt: Date(),
                                  groups: subtree, presets: inside)
        guard writeDeletedFolder(entry) else {
            ActivityLog.shared.error("Presets", "Could not move folder \(root.name) to the trash: the trash copy could not be written, so nothing was deleted")
            return
        }
        for preset in inside {
            presets.removeAll { $0.id == preset.id }
            let file = presetsDirectory.appendingPathComponent(preset.filename)
            // After any queued write for it, which the bump turns into a no-op.
            cancelPendingWrites(for: preset.id, file: file)
            Self.ioQueue.async { try? FileManager.default.removeItem(at: file) }
        }
        groups.removeAll { ids.contains($0.id) }
        saveGroups()
        // Same rule as deleting one preset: stars stay for Put Back, but
        // with none left in the library the filter turns off.
        if !presets.contains(where: { favoriteIDs.contains($0.id) }) { showFavoritesOnly = false }
        deletedFolders.insert(entry, at: 0)
        ActivityLog.shared.post(.event, "Presets", "Folder \(root.name) moved to the trash with \(inside.count) preset\(inside.count == 1 ? "" : "s")")
    }

    /// A folder in the trash: its subtree of folders and the presets that
    /// were inside, kept whole so it can be put back as it was.
    struct DeletedFolder: Identifiable, Codable {
        let id: UUID
        let name: String
        let deletedAt: Date
        let groups: [PresetGroup]
        let presets: [Preset]
    }

    /// Folders the user has deleted, newest first. Each is one file under
    /// `trash/folders/`.
    @Published var deletedFolders: [DeletedFolder] = []

    private var trashFoldersDirectory: URL {
        let dir = trashDirectory.appendingPathComponent("folders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func deletedFolderFile(_ entry: DeletedFolder) -> URL {
        trashFoldersDirectory.appendingPathComponent("\(entry.id.uuidString).json")
    }

    /// Returns false if the trash copy did not make it to disk, so the
    /// caller can refuse to delete anything.
    @discardableResult
    private func writeDeletedFolder(_ entry: DeletedFolder) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(entry)
            let url = deletedFolderFile(entry)
            try data.write(to: url, options: .atomic)
            return FileManager.default.fileExists(atPath: url.path)
        } catch {
            NSLog("PresetStore.writeDeletedFolder: \(error)")
            return false
        }
    }

    private func loadDeletedFolders() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: trashFoldersDirectory, includingPropertiesForKeys: nil) else { return }
        var loaded: [DeletedFolder] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let entry = try? JSONDecoder().decode(DeletedFolder.self, from: data) {
                loaded.append(entry)
            }
        }
        deletedFolders = loaded.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Put a trashed folder back: its folders where they were (top level if
    /// the parent is gone), then its presets.
    func restoreDeletedFolder(_ entry: DeletedFolder) {
        guard deletedFolders.contains(where: { $0.id == entry.id }) else { return }
        deletedFolders.removeAll { $0.id == entry.id }
        try? FileManager.default.removeItem(at: deletedFolderFile(entry))

        for group in entry.groups where !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
        }
        let known = Set(groups.map(\.id))
        for index in groups.indices {
            if let parent = groups[index].parentID, !known.contains(parent) {
                groups[index].parentID = nil
            }
        }
        groups.sort { $0.sortOrder < $1.sortOrder }
        saveGroups()

        for preset in entry.presets where !presets.contains(where: { $0.id == preset.id }) {
            // Not running, and a shortcut another preset took meanwhile
            // stays with that one, as with a single preset put back.
            var back = preset
            if takeDeletedBefore16(entry.deletedAt, id: back.id) { back = upgradedFromBefore16(back) }
            back.isActive = false
            clearConflictingHotKey(&back)
            savePreset(back)
        }
        ActivityLog.shared.post(.event, "Presets", "Folder \(entry.name) put back")
    }

    /// Permanently delete a trashed folder and everything that was in it.
    func permanentlyDeleteFolder(_ entry: DeletedFolder) {
        deletedFolders.removeAll { $0.id == entry.id }
        forgetStars(entry.presets.map(\.id))
        try? FileManager.default.removeItem(at: deletedFolderFile(entry))
        // Its presets' version history goes with it, unless one is live.
        let live = Set(presets.map(\.id))
        let ids = entry.presets.map(\.id).filter { !live.contains($0) }
        Self.ioQueue.async { for id in ids { self.removeVersions(of: id) } }
        noteIfEmptiedOnPurpose()
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

    /// The user's own top-level folders, listed under My Presets.
    var userTopLevelGroups: [PresetGroup] { topLevelGroups.filter { !$0.isBuiltIn } }
    /// The shipped top-level folders, listed under Built-in Presets.
    var builtInTopLevelGroups: [PresetGroup] { topLevelGroups.filter { $0.isBuiltIn } }

    /// Reorder within one of the two sidebar lists. The moved folders take
    /// the sort slots that list already occupies, in the new order, so the
    /// other list is untouched.
    func moveTopLevelGroups(builtIn: Bool, fromOffsets source: IndexSet, toOffset destination: Int) {
        var subset = builtIn ? builtInTopLevelGroups : userTopLevelGroups
        let valid = IndexSet(source.filter { $0 >= 0 && $0 < subset.count })
        guard !valid.isEmpty else { return }
        let slots = subset.map(\.sortOrder).sorted()
        subset.move(fromOffsets: valid, toOffset: min(max(destination, 0), subset.count))
        for (i, g) in subset.enumerated() {
            if let idx = groups.firstIndex(where: { $0.id == g.id }) {
                groups[idx].sortOrder = slots[i]
            }
        }
        saveGroups()
    }

    /// Every preset in the order the sidebar lists them: presets outside any
    /// folder, then the user's folders, then the built-in ones, each folder
    /// with its subfolders before its own presets, as the sidebar draws
    /// them. `presets` is sorted by each
    /// preset's place inside its own folder, mixed across folders, so it is
    /// not "higher in the sidebar".
    var presetsInSidebarOrder: [Preset] {
        func walk(_ group: PresetGroup) -> [Preset] {
            subgroups(of: group.id).flatMap(walk) + presets(in: group.id)
        }
        return presets(in: nil) + userTopLevelGroups.flatMap(walk) + builtInTopLevelGroups.flatMap(walk)
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
        // Each element of the sidebar's ForEach renders as a DisclosureGroup,
        // so when folders are expanded SwiftUI reports ROW offsets rather than
        // element offsets (see OutlineListCoordinator.moveCells(fromRows:to:)).
        // Those can point past the end of this array, and
        // MutableCollection.move traps rather than failing softly, which
        // crashed the app on any drag with a folder open.
        let valid = IndexSet(source.filter { $0 >= 0 && $0 < top.count })
        guard !valid.isEmpty else { return }
        let target = min(max(destination, 0), top.count)
        top.move(fromOffsets: valid, toOffset: target)
        for (i, g) in top.enumerated() {
            if let idx = groups.firstIndex(where: { $0.id == g.id }) {
                groups[idx].sortOrder = i
            }
        }
        saveGroups()
    }

    /// Drop one preset onto another: put `presetID` at `targetID`'s position.
    ///
    /// This is the single gesture behind both reordering inside a folder and
    /// moving between folders, which is why it takes a target ROW rather than
    /// an index: the drop tells us exactly where the user aimed. If the two
    /// live in different containers the dragged preset adopts the target's
    /// folder on the way. Both affected containers are renumbered so their
    /// `sortOrder` values stay dense.
    func movePreset(_ presetID: UUID, toPositionOf targetID: UUID) {
        guard presetID != targetID,
              let dragIdx = presets.firstIndex(where: { $0.id == presetID }),
              let target = presets.first(where: { $0.id == targetID }) else { return }

        let sourceGroup = presets[dragIdx].groupID
        let destGroup = target.groupID

        // Moving down within one folder lands after the target, moving up
        // or from another folder lands before it: always "before" meant a
        // drop on the row just below did nothing and nothing could go last.
        let current = presets(in: destGroup)
        let movingDown = sourceGroup == destGroup
            && (current.firstIndex(where: { $0.id == presetID }) ?? 0) < (current.firstIndex(where: { $0.id == targetID }) ?? 0)
        var destList = current.filter { $0.id != presetID }
        let targetAt = destList.firstIndex(where: { $0.id == targetID }) ?? destList.count
        let insertAt = movingDown ? min(targetAt + 1, destList.count) : targetAt
        presets[dragIdx].groupID = destGroup
        destList.insert(presets[dragIdx], at: insertAt)

        renumber(destList)
        if sourceGroup != destGroup {
            renumber(presets(in: sourceGroup).filter { $0.id != presetID })
            // Its new folder is saved even when its number stayed the same,
            // which renumber skips: the move was lost on relaunch.
            if let idx = presets.firstIndex(where: { $0.id == presetID }) {
                savePresetToDisk(presets[idx])
            }
        }
        presets = Self.inDisplayOrder(presets)
    }

    /// Write 0..n-1 into the given presets' sortOrder and persist the ones
    /// that actually changed. Never goes through `savePreset`, which would
    /// stamp modifiedAt and make a drag look like an edit.
    private func renumber(_ ordered: [Preset]) {
        for (i, m) in ordered.enumerated() {
            guard let idx = presets.firstIndex(where: { $0.id == m.id }) else { continue }
            if presets[idx].sortOrder != i || presets[idx].groupID != m.groupID {
                presets[idx].sortOrder = i
                savePresetToDisk(presets[idx])
            }
        }
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
        let members: [Preset]
        if let groupID = groupID {
            members = presets.filter { $0.groupID == groupID }
        } else {
            // Ungrouped or referencing a group that no longer exists
            let validIDs = Set(groups.map(\.id))
            members = presets.filter { p in
                p.groupID == nil || !validIDs.contains(p.groupID!)
            }
        }
        return Self.inDisplayOrder(members)
    }

    /// Reorder presets WITHIN one container: a folder, or the ungrouped list
    /// when `groupID` is nil.
    ///
    /// The offsets SwiftUI hands us index the visible rows of that one
    /// container, which is why this works on `presets(in:)` rather than the
    /// global array. Previously there was no preset-level `.onMove` at all, so
    /// dragging a preset landed on the FOLDER list's handler with row-based
    /// offsets and rows appeared to vanish. Positions are written back to each
    /// preset's `sortOrder` so the arrangement survives relaunch.
    func movePresets(in groupID: UUID?, fromOffsets source: IndexSet, toOffset destination: Int) {
        var visible = presets(in: groupID)
        let valid = IndexSet(source.filter { $0 >= 0 && $0 < visible.count })
        guard !valid.isEmpty else { return }
        visible.move(fromOffsets: valid, toOffset: min(max(destination, 0), visible.count))

        for (i, m) in visible.enumerated() {
            guard let idx = presets.firstIndex(where: { $0.id == m.id }) else { continue }
            guard presets[idx].sortOrder != i else { continue }
            presets[idx].sortOrder = i
            // Deliberately NOT savePreset(): that stamps modifiedAt, which
            // would make "I dragged a row" look like "I edited the preset".
            savePresetToDisk(presets[idx])
        }
        presets = Self.inDisplayOrder(presets)
    }

    // MARK: - Loading

    func loadPresets() {
        var loaded: [Preset] = []

        // Load native format presets
        JoystickMapping.droppedRowsDuringDecode = 0
        var unreadable: [String] = []
        var lossy: [String] = []
        var kept = 0
        var fileOf: [UUID: [URL]] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(at: presetsDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: file)
                    let droppedBefore = JoystickMapping.droppedRowsDuringDecode
                    let keptBefore = JoystickMapping.keptRowsDuringDecode
                    var preset = try JSONDecoder().decode(Preset.self, from: data)
                    // The file's real name, not the one written inside it:
                    // a stale inner name pointed saves and deletes at a
                    // different file, and a deleted preset came back.
                    preset.filename = file.lastPathComponent
                    kept += JoystickMapping.keptRowsDuringDecode - keptBefore
                    if JoystickMapping.droppedRowsDuringDecode > droppedBefore {
                        // Rows even raw JSON could not hold: keep the file as
                        // it is before any save here rewrites it.
                        let backup = file.appendingPathExtension("bak")
                        if !FileManager.default.fileExists(atPath: backup.path) {
                            try? FileManager.default.copyItem(at: file, to: backup)
                        }
                        lossy.append(preset.name)
                    }
                    fileOf[preset.id, default: []].append(file)
                    loaded.append(preset)
                } catch {
                    // Log instead of silently swallowing so a corrupt or
                    // schema-mismatched file is diagnosable rather than vanishing.
                    NSLog("PresetStore.loadPresets: skipping \(file.lastPathComponent): \(error)")
                    unreadable.append(file.lastPathComponent)
                }
            }
        }
        // Say so where the user can see it. A preset that quietly disappears
        // from the sidebar reads as data loss; a line in the activity log
        // with the file name reads as something that can be fixed.
        if !unreadable.isEmpty {
            ActivityLog.shared.error("Presets", "\(unreadable.count) preset file\(unreadable.count == 1 ? "" : "s") could not be read and \(unreadable.count == 1 ? "was" : "were") left in place: \(unreadable.joined(separator: ", "))")
        }
        let dropped = JoystickMapping.droppedRowsDuringDecode
        if dropped > 0 {
            ActivityLog.shared.warning("Presets", "\(dropped) binding row\(dropped == 1 ? "" : "s") could not be read in \(lossy.joined(separator: ", ")); the original file\(lossy.count == 1 ? " is" : "s are") kept beside it with .bak added")
            JoystickMapping.droppedRowsDuringDecode = 0
        }
        if kept > 0 {
            ActivityLog.shared.info("Presets", "\(kept) row\(kept == 1 ? "" : "s") could not be read (made by a newer version of InputConfig, or edited by hand), will not work in this version, and \(kept == 1 ? "is" : "are") kept unchanged in the preset file")
        }
        JoystickMapping.keptRowsDuringDecode = 0

        // A group whose rows are all screen regions but which was pinned to
        // the Touchpad template (there was no Screen template before 1.5)
        // is moved to Screen, once, and written back.
        for i in loaded.indices {
            var changed = false
            for g in loaded[i].joysticks.indices {
                let group = loaded[i].joysticks[g]
                if group.inputKind == .touchpad, !group.bindings.isEmpty,
                   group.bindings.allSatisfy({ $0.input.type == .cursorRegion }) {
                    loaded[i].joysticks[g].inputKind = .screen
                    changed = true
                }
            }
            if changed { savePresetToDisk(loaded[i]) }
        }

        // De-duplicate by preset id. Two on-disk files can end up sharing an
        // internal id (e.g. importing a preset whose id collides with an
        // existing one: import keeps the decoded id but writes a new filename).
        // Without this the sidebar shows two rows for one identity and id-keyed
        // mutations touch only one of them, diverging memory from disk. Keep the
        // most recently modified copy.
        if !loaded.isEmpty {
            var byID: [UUID: Preset] = [:]
            for p in loaded {
                if let existing = byID[p.id], existing.modifiedAt >= p.modifiedAt { continue }
                byID[p.id] = p
            }
            if byID.count != loaded.count {
                NSLog("PresetStore.loadPresets: collapsed \(loaded.count - byID.count) duplicate-id preset(s)")
                // Move the losing copies out of the presets folder, or they
                // are read again on every launch and one can come back.
                let aside = presetsDirectory.deletingLastPathComponent()
                    .appendingPathComponent("duplicates", isDirectory: true)
                try? FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
                for (id, files) in fileOf where files.count > 1 {
                    let winner = byID[id]?.filename
                    for file in files where file.lastPathComponent != winner {
                        try? FileManager.default.moveItem(at: file, to: aside.appendingPathComponent(file.lastPathComponent))
                    }
                }
                loaded = Array(byID.values)
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
        // Order by the user's explicit arrangement. Files written before
        // sortOrder existed have nil and fall back to newest-modified-first,
        // which is exactly how the sidebar used to look, so an upgrade does
        // not visibly reshuffle anyone's library. Those nils are then filled
        // in and written back once, and after that the order is stable: it no
        // longer moves just because a preset was edited.
        presets = Self.inDisplayOrder(loaded)
        migrateMissingSortOrderIfNeeded()
    }

    /// Sort by explicit position, then by recency for anything not yet placed.
    /// Ties break on name so the result is deterministic.
    static func inDisplayOrder(_ list: [Preset]) -> [Preset] {
        list.sorted { a, b in
            switch (a.sortOrder, b.sortOrder) {
            case let (x?, y?):
                if x != y { return x < y }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case (nil, _?):  return false      // unplaced sinks below placed
            case (_?, nil):  return true
            default:
                if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// One-time fill of sortOrder for presets written before it existed.
    /// Runs per container so numbering is dense inside each folder.
    private func migrateMissingSortOrderIfNeeded() {
        guard presets.contains(where: { $0.sortOrder == nil }) else { return }
        var containers: [UUID?: [Preset]] = [:]
        for p in presets { containers[p.groupID, default: []].append(p) }
        var changed: [Preset] = []
        for (_, members) in containers {
            for (i, m) in Self.inDisplayOrder(members).enumerated() {
                guard let idx = presets.firstIndex(where: { $0.id == m.id }) else { continue }
                if presets[idx].sortOrder != i {
                    presets[idx].sortOrder = i
                    changed.append(presets[idx])
                }
            }
        }
        presets = Self.inDisplayOrder(presets)
        for p in changed { savePresetToDisk(p) }
    }

    /// Re-seed example presets and (on first install only) the default
    /// groups. Presets are matched by name; groups are seeded behind a
    /// one-shot UserDefaults flag so an App Store update never overwrites a
    /// user's renamed or deleted groups.
    /// Puts back every built-in preset that is missing from the library
    /// (deleted, or lost with the presets folder), with its folder if that
    /// is gone too. A built-in still in the library, edited or not, is left
    /// alone. Returns how many came back. Before, a name once seeded was
    /// never seeded again, so a lost presets folder left no built-ins.
    @discardableResult
    func restoreBuiltInPresets() -> Int {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Self.emptiedOnPurposeKey)
        // One in the Trash counts as there: restored as well, Put Back then
        // left two copies.
        let have = Set(presets.map(\.name) + recentlyDeleted.map(\.preset.name)
                       + deletedFolders.flatMap { $0.presets.map(\.name) })
        let missing = ExamplePresets.all.map(\.name).filter { !have.contains($0) }
        guard !missing.isEmpty else { return 0 }
        let ledgerKey = "InputConfig.seededExampleNames.v1"
        var ledger = Set(defaults.stringArray(forKey: ledgerKey) ?? [])
        ledger.subtract(missing)
        defaults.set(Array(ledger).sorted(), forKey: ledgerKey)
        // An empty ledger with the seeded flag set reads as an old install
        // and stamps everything as seeded; clear the flag so they come back.
        if ledger.isEmpty { defaults.set(false, forKey: "InputConfig.seededExamples.v1") }
        defaults.set(false, forKey: "InputConfig.seededExampleGroups.v1")
        defaults.removeObject(forKey: "InputConfig.lastExampleSeedBuild")
        reseedExamplePresets()
        ActivityLog.shared.info("Presets", "Restored \(missing.count) built-in preset\(missing.count == 1 ? "" : "s")")
        return missing.count
    }

    /// At launch: an empty library with nothing in the Trash lost its files
    /// (or the first launch could not write them), so the built-ins return.
    /// Not when the person emptied it on purpose (deleted every preset and
    /// emptied the Trash): they came back at every launch.
    func restoreBuiltInsIfLibraryLost() {
        // A library with presets again was not emptied for good.
        if !presets.isEmpty { UserDefaults.standard.set(false, forKey: Self.emptiedOnPurposeKey) }
        guard presets.isEmpty, recentlyDeleted.isEmpty, deletedFolders.isEmpty,
              !UserDefaults.standard.bool(forKey: Self.emptiedOnPurposeKey),
              !(UserDefaults.standard.stringArray(forKey: "InputConfig.seededExampleNames.v1") ?? []).isEmpty else { return }
        restoreBuiltInPresets()
    }

    nonisolated static let emptiedOnPurposeKey = "InputConfig.libraryEmptiedOnPurpose"

    /// Called after a permanent delete: the library and the Trash both
    /// empty means the person emptied everything themselves.
    private func noteIfEmptiedOnPurpose() {
        guard presets.isEmpty, recentlyDeleted.isEmpty, deletedFolders.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: Self.emptiedOnPurposeKey)
    }

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
        // Only when the folders file itself was lost: a user who deleted
        // every folder but kept a built-in (moved out of its folder) got all
        // the shipped folders back on the next launch.
        let needsGroupRepair = groups.isEmpty && shipPresetsPresent && groupsFileLost

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
                    parentID: parentID,
                    isBuiltIn: true
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
        // defaults without trampling user customizations on every launch:
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
                // overwrite a color the user picked from the menu.
                groups[index].color = defaultColor
                didColorBackfill = true
            }
        }
        if didColorBackfill { saveGroups() }
        if !didApplyV2 { defaults.set(true, forKey: colorVersionKey) }

        // One-shot: the shipped Anki preset carried three paragraphs of
        // notes and a paragraph-long slot tag in 1.4. Installs that still
        // have that exact text (never edited) get the short 1.5 version.
        let ankiTrimKey = "InputConfig.trimmedAnkiNotes.v1"
        if !defaults.bool(forKey: ankiTrimKey) {
            for i in presets.indices where presets[i].name == "Anki"
                && presets[i].notes.hasPrefix("Anki from a controller.") {
                let fresh = ExamplePresets.anki
                presets[i].notes = fresh.notes
                presets[i].tag = fresh.tag
                if presets[i].joysticks.count == 1 { presets[i].joysticks[0].tag = fresh.joysticks[0].tag }
                savePresetToDisk(presets[i])
            }
            defaults.set(true, forKey: ankiTrimKey)
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

        // Seed the example presets exactly once per install, gated by a flag
        // like the group and color steps above. The previous unguarded version
        // deduped by user-editable display NAME, so renaming a built-in example
        // (or deleting one) made a fresh copy reappear on the next launch and
        // accumulate duplicates without bound.
        let exampleSeedKey = "InputConfig.seededExamples.v1"
        // Per-example seed ledger: every example NAME that has ever been
        // seeded on this install. Guarantees the two update-safety rules:
        //   1. A built-in preset the user modified, renamed, or deleted is
        //      NEVER re-added or replaced by any future app update.
        //   2. Brand-new examples shipped in an update still arrive, exactly
        //      once, because only never-ledgered names are seeded.
        let ledgerKey = "InputConfig.seededExampleNames.v1"
        var seededNames = Set(defaults.stringArray(forKey: ledgerKey) ?? [])
        // Only evaluate ExamplePresets.all (26 computed properties, each a JSON
        // decode) when it can actually matter: a fresh install (empty ledger)
        // or a new app build that may ship new examples. On an ordinary
        // same-build relaunch the ledger already contains every example, so the
        // seed loop below would skip every body anyway - gating here skips the
        // wasted 26-preset parse entirely. Step 3 self-heal below is untouched
        // and still runs every launch (it uses only the cheap static dict).
        let seedBuildKey = "InputConfig.lastExampleSeedBuild"
        // The build, plus the built-ins' own revision, so a built-in added
        // between builds (the Auto Clicker on build 30) still reaches an
        // existing library at its next launch.
        let currentBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            + "|" + String(ExamplePresets.seedRevision)
        if seededNames.isEmpty || defaults.string(forKey: seedBuildKey) != currentBuild {
            if seededNames.isEmpty && defaults.bool(forKey: exampleSeedKey) {
                // Migration for installs that seeded before the ledger existed:
                // stamp every currently-shipped example as already seeded, so
                // nothing the user has since renamed or deleted comes back.
                seededNames = Set(ExamplePresets.all.map(\.name))
                defaults.set(Array(seededNames).sorted(), forKey: ledgerKey)
            }
            var ledgerDirty = false
            for example in ExamplePresets.all where !seededNames.contains(example.name) {
                if !existingNames.contains(example.name) {
                    var copy = example
                    if let groupName = ExamplePresets.groupAssignments[example.name],
                       let groupID = groupIDsByName[groupName] {
                        copy.groupID = groupID
                    }
                    ExamplePresets.fillShippedNotes(&copy)
                    ExamplePresets.fillShippedSections(&copy)
                    ExamplePresets.fillButtonFamily(&copy)
                    savePreset(copy)
                }
                seededNames.insert(example.name)
                ledgerDirty = true
            }
            if ledgerDirty { defaults.set(Array(seededNames).sorted(), forKey: ledgerKey) }
            defaults.set(true, forKey: exampleSeedKey)
            defaults.set(currentBuild, forKey: seedBuildKey)
        }

        // One-shot, 1.6: Desktop Navigation's A clicks now, and Select All
        // moved to the right stick press (see `upgradeDesktopNavigation`).
        let desktopNavKey = "InputConfig.desktopNavigationAClicks.v1"
        if !defaults.bool(forKey: desktopNavKey) {
            for i in presets.indices where Self.upgradeDesktopNavigation(&presets[i]) {
                savePresetToDisk(presets[i])
                ActivityLog.shared.info("Presets", "Updated \(presets[i].name) for 1.6: A now clicks, and Select All moved to the right stick press")
            }
            defaults.set(true, forKey: desktopNavKey)
        }

        // One-shot, 1.6: the mouse side buttons' keys (see `upgradeSideButtonKeys`).
        let sideButtonsKey = "InputConfig.sideButtonBrackets.v1"
        if !defaults.bool(forKey: sideButtonsKey) {
            for i in presets.indices where Self.upgradeSideButtonKeys(&presets[i]) {
                savePresetToDisk(presets[i])
                ActivityLog.shared.info("Presets", "Updated \(presets[i].name) for 1.6: the side buttons send Command [ and ] for Back and Forward")
            }
            defaults.set(true, forKey: sideButtonsKey)
        }

        // One-shot, 1.6: the side buttons block their own action (see
        // `blockSideButtons`).
        let sideBlockKey = "InputConfig.sideButtonBlock.v1"
        if !defaults.bool(forKey: sideBlockKey) {
            for i in presets.indices where Self.blockSideButtons(&presets[i]) {
                savePresetToDisk(presets[i])
                ActivityLog.shared.info("Presets", "Updated \(presets[i].name) for 1.6: the side buttons no longer also do their own action")
            }
            defaults.set(true, forKey: sideBlockKey)
        }

        // One-shot, 1.6: the built-in row fixes (see `upgradeShippedRows16`).
        let rowFixesKey = "InputConfig.builtInRowFixes16.v1"
        if !defaults.bool(forKey: rowFixesKey) {
            for i in presets.indices where Self.upgradeShippedRows16(&presets[i]) {
                savePresetToDisk(presets[i])
                ActivityLog.shared.info("Presets", "Updated \(presets[i].name) for 1.6: its rows match the 1.6 built-in (see What's New)")
            }
            defaults.set(true, forKey: rowFixesKey)
        }
        // A second pass for what was added since: Motion Cursor's scroll, and
        // 1.5 notes text on untouched built-ins (the 1.6 text replaces it).
        let rowFixes2Key = "InputConfig.builtInRowFixes16.v2"
        if !defaults.bool(forKey: rowFixes2Key) {
            for i in presets.indices {
                var changed = Self.upgradeShippedRows16(&presets[i])
                if Self.refreshShippedNotes(&presets[i]) { changed = true }
                if changed { savePresetToDisk(presets[i]) }
            }
            defaults.set(true, forKey: rowFixes2Key)
        }

        // One-shot, 1.6: the drive throttle was upside down on every
        // GameController pad in 1.5, and the way round it was Invert throttle.
        // With the sign fixed, that switch would turn driving backward again.
        let throttleKey = "InputConfig.driveThrottleSign16.v1"
        if !defaults.bool(forKey: throttleKey) {
            for i in presets.indices where Self.clearThrottleWorkaround(&presets[i]) {
                savePresetToDisk(presets[i])
                ActivityLog.shared.info("Presets", "Turned off Invert throttle in \(presets[i].name): 1.6 fixed the direction it worked around")
            }
            defaults.set(true, forKey: throttleKey)
        }

        // One-shot, 1.6: installed copies of the presets written for one
        // controller family learn it, so the visualizer and editor name their
        // buttons that way. Only a copy with no family yet, and only by the
        // shipped name, so a renamed copy is left alone.
        let familiesKey = "InputConfig.presetButtonFamilies.v1"
        if !defaults.bool(forKey: familiesKey) {
            for i in presets.indices where ExamplePresets.fillButtonFamily(&presets[i]) {
                savePresetToDisk(presets[i])
            }
            defaults.set(true, forKey: familiesKey)
        }
        // The Steam Controller presets name their buttons as Steam
        // Controllers now, not as an Xbox pad; a copy still on the Xbox
        // names it was given before takes its own.
        let steamFamiliesKey = "InputConfig.presetButtonFamilies.v2"
        if !defaults.bool(forKey: steamFamiliesKey) {
            for i in presets.indices where presets[i].buttonFamily == .xbox
                && (presets[i].name == "Steam Controller" || presets[i].name == "Steam Controller (2026)") {
                presets[i].buttonFamily = ExamplePresets.buttonFamilies[presets[i].name]
                savePresetToDisk(presets[i])
            }
            defaults.set(true, forKey: steamFamiliesKey)
        }
        // The Steam Controller presets read the Steam Controller by name
        // (on Auto-detect they read slot 0, any other pad connected) and
        // take their own section headings, and the touchpad and Access
        // Controller presets name their buttons the PlayStation way. Only
        // copies still on Auto-detect, with the standard headings, or with
        // no family yet.
        let steamTargetKey = "InputConfig.presetButtonFamilies.v3"
        if !defaults.bool(forKey: steamTargetKey) {
            for i in presets.indices {
                var changed = ExamplePresets.familiedIn16v3.contains(presets[i].name)
                    && ExamplePresets.fillButtonFamily(&presets[i])
                changed = ExamplePresets.fillSteamTarget(&presets[i]) || changed
                changed = ExamplePresets.refreshSteamSections(&presets[i]) || changed
                // The notes pass above could not match a Steam copy until
                // its target was set here.
                changed = Self.refreshShippedNotes(&presets[i]) || changed
                if changed { savePresetToDisk(presets[i]) }
            }
            defaults.set(true, forKey: steamTargetKey)
        }

        // One-shot, 1.6: a Switch Pro Controller or Joy-Con pair now numbers
        // its face buttons by position (0 the bottom one), not by the letter
        // printed on them. Rows scanned from one of those pads before 1.6
        // recorded the letter's index, so they swap once to keep firing from
        // the same button. Only groups whose rows were scanned from a Switch
        // pad (their device fingerprint names one), and never a built-in,
        // which was always written by position.
        let nintendoKey = "InputConfig.nintendoFacePositions.v1"
        if !defaults.bool(forKey: nintendoKey) {
            let shipped = Set(ExamplePresets.all.map(\.name))
            for i in presets.indices where !shipped.contains(presets[i].name) {
                if Self.swapNintendoFaceRows(&presets[i]) {
                    savePresetToDisk(presets[i])
                    ActivityLog.shared.info("Presets", "Kept \(presets[i].name)'s Switch face buttons on the same buttons: 1.6 numbers them by position")
                }
            }
            defaults.set(true, forKey: nintendoKey)
        }

        // One-shot, 1.6: the presets already here were made before 1.6, so
        // rows in them recorded on a Switch pad's face buttons or an 8BitDo
        // pad's back buttons are checked when that pad first connects (see
        // LegacyRowCheck). 1.5 wrote no fingerprint, so the one-shots on
        // either side of this only reach rows scanned in a 1.6 build.
        // One-shot, 1.6: row notes 1.5 wrote on untouched built-ins.
        let rowNotesKey = "InputConfig.builtInRowNotes16.v1"
        if !defaults.bool(forKey: rowNotesKey) {
            for i in presets.indices {
                let rows = Self.refreshShippedRowNotes(&presets[i])
                let notes = Self.refreshShippedNotes(&presets[i])
                if rows || notes { savePresetToDisk(presets[i]) }
            }
            defaults.set(true, forKey: rowNotesKey)
        }
        // One-shot, 1.6: descriptions 1.5 shipped that 1.6 reworded.
        let tagsKey = "InputConfig.builtInTags16.v1"
        if !defaults.bool(forKey: tagsKey) {
            for i in presets.indices where Self.refreshShippedTags(&presets[i]) { savePresetToDisk(presets[i]) }
            defaults.set(true, forKey: tagsKey)
        }
        if defaults.object(forKey: Self.first16LaunchKey) == nil { defaults.set(Date(), forKey: Self.first16LaunchKey) }
        let olderKey = "InputConfig.legacyRowCheck.v1"
        if !defaults.bool(forKey: olderKey) {
            Self.rememberOlderRows(presets)
            defaults.set(true, forKey: olderKey)
        }

        // One-shot, 1.6: an 8BitDo pad's back buttons now read as 16 and 17
        // (their own names); before, they were numbered as unknown extras at
        // 20 and 21. Rows scanned from an 8BitDo pad move with them.
        let eightBitDoKey = "InputConfig.eightBitDoBackButtons.v1"
        if !defaults.bool(forKey: eightBitDoKey) {
            for i in presets.indices {
                var changed = false
                for g in presets[i].joysticks.indices {
                    let print = (presets[i].joysticks[g].deviceFingerprint ?? "").lowercased()
                    guard print.hasPrefix("gc:"), print.contains("8bitdo") else { continue }
                    for r in presets[i].joysticks[g].bindings.indices {
                        let input = presets[i].joysticks[g].bindings[r].input
                        if input.type == .button, input.index == 20 || input.index == 21 {
                            presets[i].joysticks[g].bindings[r].input.index = input.index - 4
                            changed = true
                        }
                    }
                }
                if changed { savePresetToDisk(presets[i]) }
            }
            defaults.set(true, forKey: eightBitDoKey)
        }

        // One-shot, 1.6: Keyboard Deck was retired (Modifier Holds and the Mac
        // keyboard rows any preset can take cover it). A copy still exactly as
        // 1.5 shipped it moves to the Trash, where it can be put back.
        // Rows are compared in full, every fine-tune included. Ignored: every
        // id at any depth (each row and each output carries a random one), and
        // the row's note and section, since other one-shots fill those. A
        // renamed copy, or one with any row changed, added or removed, is the
        // user's and stays.
        let keyboardDeckKey = "InputConfig.retiredKeyboardDeck.v1"
        if !defaults.bool(forKey: keyboardDeckKey) {
            let builtInFolder = groupIDsByName[ExamplePresets.GroupName.desktop]
            for p in presets where Self.isUntouchedKeyboardDeck(p, builtInFolder: builtInFolder) {
                // The preset in use (the one the global toggle starts) stays.
                if p.id == lastActivatedPresetId {
                    ActivityLog.shared.info("Presets", "Keyboard Deck is retired in 1.6 but kept, since it is the preset you use")
                    continue
                }
                deletePreset(p)
                ActivityLog.shared.info("Presets", "Keyboard Deck is retired in 1.6 and moved to the Trash, where it can be put back")
            }
            defaults.set(true, forKey: keyboardDeckKey)
        }

        // One-shot: shipped presets used to arrive with no notes and no row
        // notes, so the layout had to be worked out from the key codes. Fill
        // in the shipped text wherever an installed copy still has none;
        // anything the user wrote stays. Keyed by name, so a renamed preset
        // is left alone too.
        let notesKey = "InputConfig.shippedNotesFilled.v1"
        if !defaults.bool(forKey: notesKey) {
            // Two shipped layouts were wrong and are replaced outright when
            // the installed copy still carries the wrong rows: Media
            // Controller sent key codes that no key has (nothing happened),
            // and Web Browsing sent Command comma and Command period where
            // the bracket keys were meant. Edited copies do not match and
            // are left alone.
            for i in presets.indices {
                let p = presets[i]
                let codes = Set(p.joysticks.flatMap { $0.bindings.flatMap { $0.outputs.compactMap(\.keyCode) } })
                let fresh: Preset?
                if p.name == "Media Controller", !codes.isDisjoint(with: [232, 233, 234, 235, 237, 238, 128, 129, 130, 131]) {
                    fresh = ExamplePresets.all.first { $0.name == "Media Controller" }
                } else if p.name == "Web Browsing", codes.contains(54) || codes.contains(55) {
                    fresh = ExamplePresets.all.first { $0.name == "Web Browsing" }
                } else {
                    fresh = nil
                }
                if let fresh {
                    presets[i].joysticks = fresh.joysticks
                    presets[i].tag = fresh.tag
                    savePresetToDisk(presets[i])
                }
            }
            for i in presets.indices where ExamplePresets.groupAssignments[presets[i].name] != nil {
                if ExamplePresets.fillShippedNotes(&presets[i]) {
                    savePresetToDisk(presets[i])
                }
            }
            defaults.set(true, forKey: notesKey)
        }

        // One-shot: Anki's builder wrote a one-line note, so the full notes
        // never filled in. A copy still holding that exact line gets them.
        let ankiNotesKey = "InputConfig.ankiShippedNotes.v1"
        if !defaults.bool(forKey: ankiNotesKey) {
            for i in presets.indices where presets[i].name == "Anki" {
                if ExamplePresets.fillShippedNotes(&presets[i]) {
                    savePresetToDisk(presets[i])
                }
            }
            defaults.set(true, forKey: ankiNotesKey)
        }

        // One-shot: shipped presets get their rows under section headings
        // (Left stick, Buttons, D-pad...) now that the editor has sections.
        // Only copies with no sections at all are touched, so anything the
        // user organized themselves stays as they left it.
        let sectionsKey = "InputConfig.shippedSectionsFilled.v1"
        if !defaults.bool(forKey: sectionsKey) {
            for i in presets.indices where ExamplePresets.groupAssignments[presets[i].name] != nil {
                if ExamplePresets.fillShippedSections(&presets[i]) {
                    savePresetToDisk(presets[i])
                }
            }
            defaults.set(true, forKey: sectionsKey)
        }

        // One-shot: regions used to be one app-wide list per kind. Each
        // preset now carries its own, so hand every region a preset refers
        // to over to that preset. A region no preset refers to is left in
        // the old list, unused.
        let regionsKey = "InputConfig.regionsPerPreset.v1"
        if !defaults.bool(forKey: regionsKey) {
            let legacyTouchpad = TouchpadService.legacyAppWideRegions()
            let legacyCursor = CursorRegionService.legacyAppWideRegions()
            let legacyStick = StickRegionService.legacyAppWideRegions()
            for i in presets.indices {
                let refs = presets[i].referencedRegionIDs
                var changed = false
                for r in legacyTouchpad where refs.touchpad.contains(r.id)
                    && !presets[i].touchpadRegions.contains(where: { $0.id == r.id }) {
                    presets[i].touchpadRegions.append(r); changed = true
                }
                for r in legacyCursor where refs.cursor.contains(r.id)
                    && !presets[i].cursorRegions.contains(where: { $0.id == r.id }) {
                    presets[i].cursorRegions.append(r); changed = true
                }
                for (stick, list) in legacyStick {
                    for r in list where refs.stick.contains(r.id)
                        && !(presets[i].stickRegions["\(stick)"] ?? []).contains(where: { $0.id == r.id }) {
                        presets[i].stickRegions["\(stick)", default: []].append(r); changed = true
                    }
                }
                if changed { savePresetToDisk(presets[i]) }
            }
            defaults.set(true, forKey: regionsKey)
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
            // Only a dangling folder id. No folder at all is the user's
            // choice (Remove from Group), which this used to undo on every
            // launch.
            if let current = presets[index].groupID, !validGroupIDs.contains(current) {
                presets[index].groupID = groupID
                savePresetToDisk(presets[index])
            }
        }
    }

    // MARK: - Saving

    /// Block until every queued preset write and delete has run. For quit.
    static func flushPendingWrites() { ioQueue.sync {} }

    /// Save to disk only (no array update)
    /// Shared serial queue for all disk I/O so JSON encoding and file
    /// writes never block the main thread. Saving a preset with many
    /// bindings can otherwise take 100-200 ms on the main run loop,
    /// which the user feels as a freeze when clicking Save.
    nonisolated private static let ioQueue = DispatchQueue(label: "com.inputconfig.preset-io",
                                                qos: .utility)

    /// Per-preset write generation, used to coalesce a burst of superseded
    /// saves (e.g. a live ColorPicker drag firing the binding setter dozens of
    /// times/sec) down to the final write. Incremented on the MainActor in
    /// savePreset, read on ioQueue; guarded by writeGenLock. The snapshot step
    /// and the synchronous in-memory update are unaffected, so version history
    /// and UI stay identical, only redundant intermediate encode+writes drop.
    // nonisolated(unsafe): the class is @MainActor but these are touched from
    // the background ioQueue too; writeGenLock serializes all access, so the
    // manual synchronization is sound and we opt out of actor/Sendable checks.
    nonisolated(unsafe) private var writeGeneration: [UUID: Int] = [:]
    nonisolated(unsafe) private let writeGenLock = NSLock()

    /// Rewrite a preset's file without it counting as an edit: reorders
    /// and upgrade migrations keep the preset's modified date, so they do
    /// not float to the top of "recently edited" or win a duplicate check.
    private func savePresetToDisk(_ preset: Preset) {
        let fileURL = presetsDirectory.appendingPathComponent(preset.filename)
        writeGenLock.lock()
        let myGen = (writeGeneration[preset.id] ?? 0) + 1
        writeGeneration[preset.id] = myGen
        writeGenLock.unlock()
        Self.ioQueue.async {
            self.writeGenLock.lock()
            let isLatest = self.writeGeneration[preset.id] == myGen
            self.writeGenLock.unlock()
            guard isLatest else { return }
            Self.write(try? JSONEncoder().encode(preset), to: fileURL, what: "\u{201C}\(preset.name)\u{201D}")
        }
    }

    /// Posted after every preset save, carrying the saved preset. MappingEngine
    /// listens so an edit to the RUNNING preset takes effect immediately.
    static let presetSavedNotification = Notification.Name("InputConfig.PresetSaved")

    func savePreset(_ preset: Preset, forceSnapshot: Bool = false) {
        var mutable = preset
        mutable.modifiedAt = Date()
        // A preset that has never been placed (freshly seeded example, or one
        // the user just created) goes to the end of its own container. Without
        // this, new presets keep a nil sortOrder and fall back to
        // newest-modified-first, which is the unstable ordering this replaced.
        if mutable.sortOrder == nil {
            let siblings = presets.filter { $0.groupID == mutable.groupID && $0.id != mutable.id }
            mutable.sortOrder = (siblings.compactMap(\.sortOrder).max()).map { $0 + 1 } ?? siblings.count
        }
        // The engine holds a snapshot taken at start(), so without this an edit
        // to the active preset did nothing until the preset was restarted or
        // the app quit: deleted bindings kept firing and new ones stayed dead.
        defer {
            NotificationCenter.default.post(
                name: Self.presetSavedNotification, object: nil,
                userInfo: ["preset": mutable])
        }
        // The store owns which preset is running: the editor's copy carries
        // the flag from when the sheet opened, and a Save after a stop or a
        // switch marked a preset running that was not (or the reverse).
        let prior = presets.first(where: { $0.id == mutable.id })
        if prior != nil { mutable.isActive = mutable.id == activePresetId }
        // A save that changes only words (notes, name, tag) takes no
        // snapshot: the notes field saves on every keystroke, and ten slow
        // keystrokes pushed every real earlier version out of the history.
        let wordsOnly: Bool = {
            guard var before = prior else { return false }
            before.notes = mutable.notes
            before.name = mutable.name
            before.tag = mutable.tag
            before.modifiedAt = mutable.modifiedAt
            before.isActive = mutable.isActive
            before.sortOrder = mutable.sortOrder
            return before == mutable
        }()
        let fileURL = presetsDirectory.appendingPathComponent(mutable.filename)

        // Snapshot the prior contents (if any) before overwriting, so the
        // user can revert. Capture mutates only the prior file, not the new
        // one - so this runs before the encode of the new state.
        let priorFile = fileURL
        let snapshotDir = versionsDirectory.appendingPathComponent(mutable.id.uuidString)

        // Bump this preset's write generation now (on the MainActor). A later
        // savePreset for the same id enqueued while this one waits will raise
        // the generation, so the stale block below skips its encode+write.
        writeGenLock.lock()
        let myGen = (writeGeneration[mutable.id] ?? 0) + 1
        writeGeneration[mutable.id] = myGen
        writeGenLock.unlock()

        // Update the in-memory model immediately so the UI stays in sync,
        // but push the encode + write to a background queue so the Save
        // button feels instant.
        Self.ioQueue.async {
            // 1. Snapshot the prior file content alongside its modification
            //    timestamp (used as the snapshot filename). Throttled: typing a
            //    preset name calls savePreset on every keystroke, which used to
            //    spam the version history with partial-typing states and evict
            //    meaningful older versions (the prune keeps only the most recent
            //    10). Skip the snapshot when the newest existing snapshot is only
            //    seconds old, so an editing burst leaves at most one checkpoint.
            //    The new state itself is always written below, so no edit is lost.
            if let priorData = try? Data(contentsOf: priorFile) {
                let newestSnapshotAge: TimeInterval = {
                    guard let existing = try? FileManager.default.contentsOfDirectory(
                        at: snapshotDir, includingPropertiesForKeys: [.contentModificationDateKey]),
                        !existing.isEmpty else { return .greatestFiniteMagnitude }
                    let newest = existing.compactMap {
                        try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    }.max() ?? .distantPast
                    return Date().timeIntervalSince(newest)
                }()
                if forceSnapshot || (newestSnapshotAge >= 3.0 && !wordsOnly) {
                    try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                    // Milliseconds: two forced snapshots in one second
                    // used to share a name, and the second replaced the first.
                    let snapName = "\(Int(Date().timeIntervalSince1970 * 1000)).json"
                    let snapURL = snapshotDir.appendingPathComponent(snapName)
                    try? priorData.write(to: snapURL, options: .atomic)
                    // The preset page's Previous versions list reloads, so
                    // the version just saved is there to revert to at once.
                    let id = mutable.id
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Self.versionsChangedNotification, object: id)
                    }
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
            }

            // 2. Write the new state, unless a newer save for this preset was
            //    enqueued while this one waited (color-drag burst): the final
            //    generation still writes, intermediate ones nobody reads drop.
            self.writeGenLock.lock()
            let isLatest = self.writeGeneration[mutable.id] == myGen
            self.writeGenLock.unlock()
            guard isLatest else { return }
            Self.write(try? JSONEncoder().encode(mutable), to: fileURL, what: "\u{201C}\(mutable.name)\u{201D}")
        }

        if let index = presets.firstIndex(where: { $0.id == mutable.id }) {
            presets[index] = mutable
        } else {
            presets.insert(mutable, at: 0)
        }
    }

    // MARK: - Version history

    /// Posted (object: the preset's UUID) after a new version is kept.
    nonisolated static let versionsChangedNotification = Notification.Name("InputConfig.presetVersionsChanged")

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
        // Restore the FULL snapshot (light, notes, automation, cursor flags,
        // every field) instead of a lossy memberwise init, keeping the live
        // preset's identity so it stays the same sidebar entry.
        var restored = version.preset
        let old = version.preset.writtenByFormatVersion < Preset.currentFormatVersion
        restored.filename = preset.filename
        restored.isActive = preset.isActive
        // savePreset will set modifiedAt; preserve createdAt from the live
        // preset since the snapshot represented an older save.
        restored.createdAt = preset.createdAt
        // Reassign the live UUID via Codable round-trip (struct is value
        // type, so we serialize+rewrite to put the original id back).
        if let data = try? JSONEncoder().encode(restored),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict["id"] = preset.id.uuidString
            if let patched = try? JSONSerialization.data(withJSONObject: dict),
               var final = try? JSONDecoder().decode(Preset.self, from: patched) {
                // A version saved before 1.6 gets the same upgrades the
                // preset got, under the live id the row check keys on.
                if old { final = upgradedFromBefore16(final) }
                // A shortcut another preset took since that version stays
                // with that one.
                clearConflictingHotKey(&final)
                savePreset(final, forceSnapshot: true)
                return
            }
        }
        // Fallback: save with whatever the snapshot's id was (which will
        // appear as a "new" preset in the sidebar).
        if old { restored = upgradedFromBefore16(restored) }
        clearConflictingHotKey(&restored)
        savePreset(restored, forceSnapshot: true)
    }

    /// Public URL of the preset's JSON file on disk. Used by the "Open in
    /// Finder" action in PresetDetailView.
    func fileURL(for preset: Preset) -> URL {
        presetsDirectory.appendingPathComponent(preset.filename)
    }

    // MARK: - CRUD

    func createPreset() -> Preset {
        var preset = Preset(name: "New Preset", joysticks: [JoystickMapping(tag: "")])
        // The newest preset goes to the top of My Presets, where the New
        // Preset button is, so it is never hidden below the built-ins.
        let minOrder = presets(in: nil).compactMap(\.sortOrder).min() ?? 1
        preset.sortOrder = minOrder - 1
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
        // Its star stays while it is in the Trash, so Put Back brings it
        // back starred (as a folder's presets always were); it goes on a
        // permanent delete. With no starred preset left in the library the
        // filter turns off, or it stayed on unseen and flipped the sidebar.
        if !presets.contains(where: { $0.id != preset.id && favoriteIDs.contains($0.id) }) { showFavoritesOnly = false }
        // Never stored as running: put back, it came back marked active with
        // nothing running, and its Deactivate stopped the preset that was.
        var preset = preset
        preset.isActive = false
        presets.removeAll { $0.id == preset.id }

        // Move the on-disk file from presets/ to trash/ instead of
        // deleting it. Restoring is then a simple move-back operation.
        // On the save queue, after any write still waiting for this preset
        // (which the generation bump turns into a no-op): moving first let a
        // queued write recreate the file, and the deleted preset came back.
        let source = presetsDirectory.appendingPathComponent(preset.filename)
        let dest = trashDirectory.appendingPathComponent(preset.filename)
        cancelPendingWrites(for: preset.id, file: source)
        Self.ioQueue.async {
            // If the destination already exists (re-deleted preset), remove
            // the old copy first so the move can succeed.
            try? FileManager.default.removeItem(at: dest)
            // The preset as it is now, not the file on disk: the newest
            // write was just called off, so the file could be an older save,
            // and Put Back after a relaunch returned that.
            if let data = try? JSONEncoder().encode(preset), (try? data.write(to: dest, options: .atomic)) != nil {
                try? FileManager.default.removeItem(at: source)
            } else {
                try? FileManager.default.moveItem(at: source, to: dest)
            }
            // The deletion date, which Recently Deleted reads back at launch.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        }

        recentlyDeleted.insert(DeletedPreset(preset: preset, deletedAt: Date()), at: 0)
        pruneTrash()
    }

    /// Cap on how many deleted presets stay in Recently Deleted. Older entries
    /// are pruned (and their on-disk trash file removed) so heavy create/delete
    /// or import churn can't grow the trash folder or this @Published list
    /// without bound. Mirrors the 10-snapshot cap on per-preset version history.
    private static let trashCap = 60

    private func pruneTrash() {
        guard recentlyDeleted.count > Self.trashCap else { return }
        // recentlyDeleted is newest-first, so the overflow to drop is the tail.
        // A preset that is live again, or still inside a trashed folder,
        // keeps its version history.
        let kept = Set(presets.map(\.id)).union(deletedFolders.flatMap { $0.presets.map(\.id) })
        let dropped = recentlyDeleted[Self.trashCap...].map(\.preset.name)
        ActivityLog.shared.info("Presets", "The Trash keeps the last \(Self.trashCap) presets; deleted for good: " + dropped.joined(separator: ", "))
        for entry in recentlyDeleted[Self.trashCap...] {
            let file = trashDirectory.appendingPathComponent(entry.preset.filename)
            let id = entry.preset.id
            let keepVersions = kept.contains(id)
            Self.ioQueue.async {
                try? FileManager.default.removeItem(at: file)
                if !keepVersions { self.removeVersions(of: id) }
            }
        }
        recentlyDeleted.removeLast(recentlyDeleted.count - Self.trashCap)
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
        cancelPendingWrites(for: preset.id, file: source)
        Self.ioQueue.async {
            try? FileManager.default.removeItem(at: source)
            self.removeVersions(of: preset.id)
        }
    }

    /// Make any write still queued for this preset skip itself.
    /// `file`: the preset's file, whose failed write (kept for a retry) is
    /// dropped too, or the retry wrote a deleted preset back.
    private func cancelPendingWrites(for id: UUID, file: URL? = nil) {
        writeGenLock.lock()
        writeGeneration[id, default: 0] += 1
        writeGenLock.unlock()
        if let file {
            Self.failedLock.lock(); Self.failedWrites[file] = nil; Self.failedLock.unlock()
        }
    }

    /// A permanently deleted preset's version history goes with it.
    nonisolated private func removeVersions(of id: UUID) {
        let dir = presetsDirectory.deletingLastPathComponent()
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Re-create a previously-deleted preset. Moves the JSON back from
    /// trash/ to presets/ and drops the entry from `recentlyDeleted`.
    @discardableResult
    func restoreDeleted(_ entry: DeletedPreset) -> Bool {
        guard recentlyDeleted.contains(where: { $0.id == entry.id }) else { return false }
        recentlyDeleted.removeAll { $0.id == entry.id }
        // A queued move into the trash finishes first, or putting a preset
        // back right after deleting it found no trash file yet and the late
        // move then took the restored file away again.
        Self.flushPendingWrites()
        // Already live again (a backup restore brought it back): leave the
        // live one alone rather than overwrite it with the trash copy.
        if presets.contains(where: { $0.id == entry.preset.id }) {
            try? FileManager.default.removeItem(at: trashDirectory.appendingPathComponent(entry.preset.filename))
            return true
        }

        let trashed = trashDirectory.appendingPathComponent(entry.preset.filename)
        let restored = presetsDirectory.appendingPathComponent(entry.preset.filename)
        if FileManager.default.fileExists(atPath: trashed.path) {
            try? FileManager.default.removeItem(at: restored)
            try? FileManager.default.moveItem(at: trashed, to: restored)
        }

        // savePreset re-inserts into in-memory `presets` (no-op file
        // write is fine - the file already exists at the target). A shortcut
        // another preset took meanwhile goes to that one.
        var back = entry.preset
        if takeDeletedBefore16(entry.deletedAt, id: back.id) { back = upgradedFromBefore16(back) }
        back.isActive = false
        clearConflictingHotKey(&back)
        savePreset(back)
        return true
    }

    /// Permanently delete a single trash entry. Removes the on-disk file
    /// and the in-memory record. Use sparingly - the user can no longer
    /// restore after this.
    func permanentlyDelete(_ entry: DeletedPreset) {
        recentlyDeleted.removeAll { $0.id == entry.id }
        forgetStars([entry.preset.id])
        let url = trashDirectory.appendingPathComponent(entry.preset.filename)
        let id = entry.preset.id
        // The same preset can be live again (a backup restore); its version
        // history is then the live preset's and stays.
        let live = presets.contains { $0.id == id }
            || deletedFolders.contains { $0.presets.contains { $0.id == id } }
        Self.ioQueue.async {
            try? FileManager.default.removeItem(at: url)
            if !live { self.removeVersions(of: id) }
        }
        noteIfEmptiedOnPurpose()
    }

    /// Permanently delete everything in the trash. The on-disk trash
    /// folder is wiped along with the in-memory list.
    func emptyTrash() {
        // Queued moves into the trash finish first, or a file still on its
        // way in was left behind and came back on the next launch.
        Self.flushPendingWrites()
        // Folders' presets too, whose version history piled up on disk; not
        // a preset that is live again.
        let live = Set(presets.map(\.id))
        let ids = (recentlyDeleted.map(\.preset.id) + deletedFolders.flatMap { $0.presets.map(\.id) })
            .filter { !live.contains($0) }
        Self.ioQueue.async { for id in ids { self.removeVersions(of: id) } }
        forgetStars(ids)
        recentlyDeleted.removeAll()
        deletedFolders.removeAll()
        try? FileManager.default.removeItem(at: trashFoldersDirectory)
        if let files = try? FileManager.default.contentsOfDirectory(at: trashDirectory,
                                                                     includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        noteIfEmptiedOnPurpose()
    }

    /// Re-insert a previously-trashed preset from a backup envelope.
    /// Writes the JSON to trash/ on disk and pushes it into the
    /// in-memory `recentlyDeleted` list so the trash survives a
    /// machine migration. Skips when the preset ID is already in the
    /// trash (idempotent backup restore).
    func restoreTrashFromBackup(preset: Preset, deletedAt: Date) {
        if recentlyDeleted.contains(where: { $0.preset.id == preset.id }) { return }
        // A file name with a path in it would write outside the Trash folder.
        var preset = preset
        if preset.filename.contains("/") || preset.filename.contains("..") || preset.filename.isEmpty {
            preset.filename = Preset.generateFilename()
        }
        // Still inside a folder in the Trash here: not a second, loose copy.
        if deletedFolders.contains(where: { $0.presets.contains { $0.id == preset.id } }) { return }
        let target = trashDirectory.appendingPathComponent(preset.filename)
        if let data = try? JSONEncoder().encode(preset) {
            try? data.write(to: target, options: .atomic)
            // Keep the original deletion date, which Recently Deleted
            // reads back from the file at launch.
            try? FileManager.default.setAttributes([.modificationDate: deletedAt], ofItemAtPath: target.path)
        }
        // In date order, newest first, so pruning past the cap drops the
        // oldest, not this Mac's newer entries.
        let entry = DeletedPreset(preset: preset, deletedAt: deletedAt)
        let at = recentlyDeleted.firstIndex { $0.deletedAt < deletedAt } ?? recentlyDeleted.count
        recentlyDeleted.insert(entry, at: at)
        pruneTrash()
    }

    /// What a backup restore did, for the summary shown afterwards.
    struct RestoreSummary {
        var presetsAdded = 0
        var builtInsReplaced = 0
        var presetsSkipped = 0
        var groupsAdded = 0
        var trashAdded = 0
        var unreadable = 0
        /// Restored presets that open apps or websites, or start by
        /// themselves when an app comes to the front, so the summary can say.
        var withOpeners: [String] = []
        /// A preset in the backup that is the same as one already here, by
        /// its backup id and this Mac's id, so stars and Activate Preset
        /// targets that name it follow to the copy that was kept.
        var idMap: [UUID: UUID] = [:]
    }

    // MARK: - Built-in upgrades from 1.5

    /// Every 1.6 upgrade of a shipped 1.5 layout, applied to one preset. The
    /// one-shots run these on installed copies; restoring a 1.5 backup runs
    /// them on the backup's copy, so an untouched 1.5 built-in is seen as
    /// untouched instead of coming back a second time "(from backup)".
    static func upgradedFrom15(_ preset: Preset) -> Preset {
        var p = preset
        upgradeDesktopNavigation(&p)
        upgradeSideButtonKeys(&p)
        blockSideButtons(&p)
        upgradeShippedRows16(&p)
        clearThrottleWorkaround(&p)
        refreshShippedNotes(&p)
        return p
    }

    /// Row notes still exactly as 1.5 wrote them, on a built-in whose rows
    /// are the 1.6 built-in's, take the 1.6 text, so they agree with the
    /// preset's notes. A note the user wrote is never touched.
    @discardableResult
    static func refreshShippedRowNotes(_ p: inout Preset) -> Bool {
        guard let old = ExamplePresets.rowNotes15[p.name],
              var example = ExamplePresets.all.first(where: { $0.name == p.name }),
              matchesShipped(p, example, builtInFolder: p.groupID) else { return false }
        ExamplePresets.fillShippedNotes(&example)
        var fresh: [String: String] = [:]
        for row in example.joysticks.flatMap(\.bindings) { if let n = row.note { fresh[row.input.serialized] = n } }
        var changed = false
        for g in p.joysticks.indices {
            for r in p.joysticks[g].bindings.indices {
                let key = p.joysticks[g].bindings[r].input.serialized
                let note = (p.joysticks[g].bindings[r].note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let was = old[key], note == was, let now = fresh[key], now != note {
                    p.joysticks[g].bindings[r].note = now
                    changed = true
                }
            }
        }
        return changed
    }

    /// When 1.6 first ran here, for telling a preset deleted before then.
    static let first16LaunchKey = "InputConfig.first16LaunchAt"

    /// Everything 1.6 does once to the presets already here, for a preset
    /// that missed it: one put back from Recently Deleted that was deleted
    /// before 1.6 first ran. Its Switch and 8BitDo rows join the check made
    /// when those pads connect.
    func upgradedFromBefore16(_ preset: Preset) -> Preset {
        var p = Self.upgradedFrom15(preset)
        ExamplePresets.fillButtonFamily(&p)
        ExamplePresets.fillSteamTarget(&p)
        ExamplePresets.refreshSteamSections(&p)
        Self.refreshShippedNotes(&p)
        Self.refreshShippedRowNotes(&p)
        Self.refreshShippedTags(&p)
        Self.rememberOlderRows([p])
        return p
    }

    /// Whether a trash entry was deleted before 1.6 first ran here.
    /// Called on Put Back, which uses up the restore's marks: a later delete
    /// is judged by its own date, so the 1.5 upgrades never run twice.
    private func takeDeletedBefore16(_ date: Date, id: UUID) -> Bool {
        let defaults = UserDefaults.standard
        let marked = (defaults.stringArray(forKey: Self.trashBefore16Key) ?? []).contains(id.uuidString)
        let from16 = (defaults.stringArray(forKey: Self.trashFrom16Key) ?? []).contains(id.uuidString)
        for key in [Self.trashBefore16Key, Self.trashFrom16Key] {
            if let list = defaults.stringArray(forKey: key), list.contains(id.uuidString) {
                defaults.set(list.filter { $0 != id.uuidString }, forKey: key)
            }
        }
        if marked { return true }
        if from16 { return false }
        guard let first = defaults.object(forKey: Self.first16LaunchKey) as? Date else { return false }
        return date < first
    }

    /// Trash entries restored from a 1.6 backup: never given the pre-1.6
    /// upgrades on Put Back. Mac-local, like the other upgrade records.
    static let trashFrom16Key = "InputConfig.legacyRowCheck.trashFrom16"
    /// Trash entries restored from a backup that 1.6 never upgraded.
    static let trashBefore16Key = "InputConfig.legacyRowCheck.trashBefore16"
    static func markTrash(_ id: UUID, key: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !list.contains(id.uuidString) { list.append(id.uuidString) }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// Invert throttle on a stick-driven drive, turned on in 1.5 to undo the
    /// upside-down throttle that 1.6 fixed.
    @discardableResult
    static func clearThrottleWorkaround(_ p: inout Preset) -> Bool {
        guard var drive = p.driveConfig, drive.invertThrottle, !drive.throttleIsTrigger else { return false }
        drive.invertThrottle = false
        p.driveConfig = drive
        return true
    }

    /// The preset and group descriptions 1.6 reworded (ExamplePresets.tags15):
    /// each one still exactly as 1.5 shipped it takes the 1.6 wording; one
    /// the user rewrote is left alone.
    @discardableResult
    static func refreshShippedTags(_ p: inout Preset) -> Bool {
        guard let old = ExamplePresets.tags15[p.name],
              let example = ExamplePresets.all.first(where: { $0.name == p.name }) else { return false }
        var changed = false
        if p.tag == old.preset, example.tag != old.preset { p.tag = example.tag; changed = true }
        for g in p.joysticks.indices where g < old.groups.count && g < example.joysticks.count {
            if p.joysticks[g].tag == old.groups[g], example.joysticks[g].tag != old.groups[g] {
                p.joysticks[g].tag = example.joysticks[g].tag
                changed = true
            }
        }
        return changed
    }

    /// Notes 1.5 wrote for a built-in become the 1.6 text, but only when the
    /// rest of the preset is the 1.6 built-in: on a copy whose rows were not
    /// upgraded (the user had changed them), the new text described buttons
    /// that copy does not have.
    @discardableResult
    static func refreshShippedNotes(_ p: inout Preset) -> Bool {
        let notes = p.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty, ExamplePresets.isShippedNotes(notes, for: p.name),
              let text = ExamplePresets.presetNotes[p.name], notes != text,
              let example = ExamplePresets.all.first(where: { $0.name == p.name }),
              matchesShipped(p, example, builtInFolder: p.groupID) else { return false }
        p.notes = text
        return true
    }

    /// Desktop Navigation's A clicks now, and Select All moved to the right
    /// stick press. Only a copy whose rows still send exactly what the old
    /// shipped layout sent is updated; a copy with any row changed, added or
    /// removed is the user's and is left alone.
    @discardableResult
    static func upgradeDesktopNavigation(_ p: inout Preset) -> Bool {
        guard p.name == "Desktop Navigation", p.joysticks.count == 1,
              let fresh = ExamplePresets.all.first(where: { $0.name == "Desktop Navigation" }) else { return false }
        func signature(_ p: Preset) -> [String: String] {
            var sig: [String: String] = [:]
            for group in p.joysticks {
                for b in group.bindings {
                    sig[b.input.serialized] = b.outputs.map(\.serialized).joined(separator: "|")
                }
            }
            return sig
        }
        var old = signature(fresh)
        old["btn 0"] = [OutputAction(type: .key, keyCode: 227), OutputAction(type: .key, keyCode: 4)]
            .map(\.serialized).joined(separator: "|")
        old.removeValue(forKey: "btn 12")
        guard signature(p) == old else { return false }
        var rows = p.joysticks[0].bindings
        if let a = rows.firstIndex(where: { $0.input.serialized == "btn 0" }) {
            rows[a].outputs = [OutputAction(type: .mouseButton, mouseButtonIndex: 0)]
            if rows[a].note == "Select all (Cmd A)" { rows[a].note = "Left click" }
        }
        var selectAll = BindingModel(input: .button(12),
                                     outputs: [OutputAction(type: .key, keyCode: 227),
                                               OutputAction(type: .key, keyCode: 4)])
        selectAll.note = "Select all (Cmd A)"
        if rows.contains(where: { !($0.section ?? "").isEmpty }) {
            selectAll.section = ControllerScaffold.grouped([selectAll]).first?.section
        }
        rows.append(selectAll)
        p.joysticks[0].bindings = rows
        if p.notes.contains("Face buttons: A selects all") {
            p.notes = ExamplePresets.presetNotes["Desktop Navigation"] ?? p.notes
        }
        return true
    }

    /// The mouse side buttons in Trackpad & Mouse and Keyboard & Mouse Input
    /// sent Command with keypad 3 and 4 (91, 92) instead of Command with [
    /// and ] (47, 48), so back and forward did nothing. A row is corrected
    /// only while it still sends exactly the old keys.
    @discardableResult
    static func upgradeSideButtonKeys(_ p: inout Preset) -> Bool {
        guard ["Trackpad & Mouse", "Keyboard & Mouse Input"].contains(p.name) else { return false }
        let fixes: [String: Int] = ["key 91": 47, "key 92": 48]
        var changed = false
        for g in p.joysticks.indices {
            for r in p.joysticks[g].bindings.indices {
                let row = p.joysticks[g].bindings[r]
                guard row.input.type == .extMouse, [3, 4].contains(row.input.index),
                      row.outputs.count == 2, row.outputs[0].serialized == "key 227",
                      let fixed = fixes[row.outputs[1].serialized] else { continue }
                p.joysticks[g].bindings[r].outputs[1].keyCode = fixed
                changed = true
            }
        }
        return changed
    }

    /// The same two presets' side-button rows block the button's own
    /// action, so Back and Forward go one page in Chrome and Firefox instead
    /// of two. Only rows still exactly as shipped.
    @discardableResult
    static func blockSideButtons(_ p: inout Preset) -> Bool {
        guard ["Trackpad & Mouse", "Keyboard & Mouse Input"].contains(p.name) else { return false }
        var changed = false
        for g in p.joysticks.indices {
            for r in p.joysticks[g].bindings.indices {
                let row = p.joysticks[g].bindings[r]
                guard row.input.type == .extMouse, [3, 4].contains(row.input.index),
                      row.blockOriginal == nil,
                      row.outputs.map(\.serialized) == ["key 227", row.input.index == 3 ? "key 47" : "key 48"]
                else { continue }
                p.joysticks[g].bindings[r].blockOriginal = true
                changed = true
            }
        }
        return changed
    }

    /// The built-in row fixes, which reached new installs only.
    /// Rows that still send exactly what 1.5 shipped take the 1.6 rows:
    /// Knob Deck scrolls from a pan knob (CC 10) instead of the mod wheel,
    /// Transport Control's D-pad sends CC 20 and 21 instead of dropping
    /// CC 7 to 0, Minecraft's right stick click swaps hands (F), the PS5
    /// FPS touchpad opens the map (M) with R3 taking Use (E), and Menu is
    /// Escape with View on Tab (Racing Game too). Rows that only work together (a swap, a
    /// knob's two halves) change only when every one of them is as
    /// shipped. Any row the user changed is theirs and stays; notes and
    /// the group's description still holding the 1.5 text follow.
    @discardableResult
    static func upgradeShippedRows16(_ preset: inout Preset) -> Bool {
        /// A row as 1.5 shipped it, keyed in the table by the input of
        /// the 1.6 row that replaces it.
        struct OldRow { let input: InputEvent; let outputs: [OutputAction]; let note: String? }
        struct OldPreset { let groups: [[String: OldRow]]; let notes: String?; let joystickTag: String? }
        func key(_ code: Int) -> [OutputAction] { [OutputAction(type: .key, keyCode: code)] }
        // An earlier spelling pass may have touched the shipped text.
        func same(_ a: String?, _ b: String?) -> Bool {
            func norm(_ t: String?) -> String {
                (t ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "centre", with: "center")
            }
            return norm(a) == norm(b)
        }
        let menuSwap: [String: OldRow] = [
            "btn 8": OldRow(input: .button(8), outputs: key(41), note: "Menu (Escape)"),
            "btn 9": OldRow(input: .button(9), outputs: key(43), note: "Scoreboard (Tab)"),
        ]
        let table: [String: OldPreset] = [
            "MIDI: Knob Deck": OldPreset(groups: [[
                InputEvent.midi(.cc, number: 10, direction: .positive, ccMode: .centered).serialized: OldRow(
                    input: .midi(.cc, number: 1, direction: .positive, ccMode: .centered),
                    outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .positive, speed: 6)],
                    note: "Mod wheel above center: scroll up, faster the further you push"),
                InputEvent.midi(.cc, number: 10, direction: .negative, ccMode: .centered).serialized: OldRow(
                    input: .midi(.cc, number: 1, direction: .negative, ccMode: .centered),
                    outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 6)],
                    note: "Mod wheel below center: scroll down"),
            ]], notes: "A MIDI controller runs the Mac. CC 7 (a fader) is the Mac's volume, the mod wheel scrolls, CC 71 turned sends the arrow keys, the sustain pedal clicks, pads 36 and 37 send Return and Escape. Pick your MIDI device in the slot's input kind menu.",
               joystickTag: "CC 7 = volume fader, mod wheel = scroll, CC 71 = arrows, pedal = click"),
            // One group: the two halves are a pair a DAW learns together, and
            // upgrading one split it while the notes described both.
            "MIDI: Transport Control": OldPreset(groups: [
                ["hat 0 U": OldRow(input: .hat(0, direction: .up),
                                   outputs: [OutputAction(type: .midiCC, midiCCNumber: 7, midiCCValue: 127, midiChannel: 1)],
                                   note: "Volume up (CC 7)"),
                 "hat 0 D": OldRow(input: .hat(0, direction: .down),
                                   outputs: [OutputAction(type: .midiCC, midiCCNumber: 7, midiCCValue: 0, midiChannel: 1)],
                                   note: "Volume down (CC 7)")],
            ], notes: "A DAW remote over MIDI. A starts, B stops, X continues (MIDI transport messages), the bumpers select patch 1 and patch 2 with program changes, the D-pad nudges CC 7 volume. Map them in your DAW's control surface or MIDI Learn settings.",
               joystickTag: "A = Start, B = Stop, X = Continue, LB/RB = patch up/down"),
            "Minecraft": OldPreset(groups: [
                ["btn 12": OldRow(input: .button(12), outputs: key(62), note: "Swap hands (F)")],
                ["btn 8": OldRow(input: .button(8), outputs: key(41), note: "Escape (menu)"),
                 "btn 9": OldRow(input: .button(9), outputs: key(43), note: "Player list (Tab)")],
            ], notes: nil, joystickTag: nil),
            "FPS (PS5 DualSense)": OldPreset(groups: [[
                "btn 12": OldRow(input: .button(12), outputs: key(25), note: "V"),
                "btn 13": OldRow(input: .button(13), outputs: key(8), note: "Map (M)"),
            ], [
                // A copy from a 1.6 beta, with R3 already on E.
                "btn 12": OldRow(input: .button(12), outputs: key(8), note: "Use (E)"),
                "btn 13": OldRow(input: .button(13), outputs: key(8), note: "Map (M)"),
            ]], notes: "A first-person layout for games with no controller support. Left stick moves, right stick looks, R2 fires, L2 aims. Cross jumps, Circle crouches with Control, Square reloads, Triangle is slot 1. L1 is slot 4, R1 middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. L3 sprints with Shift, R3 sends V. The touchpad press opens the map with M. Share is Tab, Options is Escape.\n\nThe touchpad can also be a trackpad; see the Touchpad Mouse preset.",
               joystickTag: nil),
            "Racing Game": OldPreset(groups: [[
                "btn 8": OldRow(input: .button(8), outputs: key(41), note: "Menu (Escape)"),
                "btn 9": OldRow(input: .button(9), outputs: key(43), note: "Tab"),
            ]], notes: "Any racing game that takes keyboard input. Left stick steers with A and D, right trigger is the throttle (W), left trigger the brake (S). A is the handbrake, B shifts up with Shift, X sends E, Y sends R for reset, bumpers send Q and F. Right stick looks around. Back is Escape, Start is Tab.\n\nChange the letters on each row to match the game's own key list; most racers let you rebind.",
               joystickTag: nil),
            "FPS (Xbox)": OldPreset(groups: [menuSwap],
                                    notes: "A first-person layout for games with no controller support. Left stick moves, right stick looks, right trigger fires, left trigger aims. A jumps, B is C for crouch, X reloads, Y is slot 1. LB is slot 4, RB middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. Left stick click sprints with Shift, right stick click sends E. View is Escape, Menu is Tab.",
                                    joystickTag: nil),
            // Its right stick scrolled the opposite way to every other
            // pointer preset.
            "Motion Cursor": OldPreset(groups: [[
                "axi 3 +": OldRow(input: .axis(3, direction: .positive),
                                  outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 4)],
                                  note: "Scroll up"),
                "axi 3 -": OldRow(input: .axis(3, direction: .negative),
                                  outputs: [OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .positive, speed: 4)],
                                  note: "Scroll down"),
            ]], notes: nil, joystickTag: nil),
            "FPS (8BitDo)": OldPreset(groups: [menuSwap],
                                      notes: "The first-person layout tuned for 8BitDo pads in A (Apple) mode. Left stick moves, right stick looks, right trigger fires, left trigger aims. A jumps, B is C for crouch, X reloads, Y is slot 1. L1 is slot 4, R1 middle-clicks. D-pad up and down scroll weapons, left is Q, right is F. Left stick click sprints, right stick click sends E. Select is Escape, Start is Tab.\n\nSet the mode switch on the back to A before pairing.",
                                      joystickTag: nil),
        ]
        func outputs(_ list: [OutputAction]) -> [String] { list.map(\.serialized) }
        guard let old = table[preset.name],
              let fresh = ExamplePresets.all.first(where: { $0.name == preset.name }),
              fresh.joysticks.count == 1, preset.joysticks.count == 1 else { return false }
        let name = preset.name
        var rows = preset.joysticks[0].bindings
        var changed = false
        for group in old.groups {
            // Every row of the group present exactly once and still exactly
            // as shipped, and no row already on a 1.6 input that is not part
            // of the group.
            let matches = group.allSatisfy { newKey, oldRow in
                let hits = rows.filter { $0.input.serialized == oldRow.input.serialized }
                guard hits.count == 1, outputs(hits[0].outputs) == outputs(oldRow.outputs) else { return false }
                return newKey == oldRow.input.serialized
                    || !rows.contains(where: { $0.input.serialized == newKey })
            }
            guard matches else { continue }
            for (newKey, oldRow) in group {
                guard let r = rows.firstIndex(where: { $0.input.serialized == oldRow.input.serialized }),
                      let freshRow = fresh.joysticks[0].bindings.first(where: { $0.input.serialized == newKey })
                else { continue }
                rows[r].input = freshRow.input
                rows[r].outputs = freshRow.outputs
                if (rows[r].note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || same(rows[r].note, oldRow.note) {
                    rows[r].note = freshRow.note ?? ExamplePresets.rowNotes[name]?[newKey]
                }
                changed = true
            }
        }
        guard changed else { return false }
        preset.joysticks[0].bindings = rows
        // The notes and tag describe the whole new layout, so they change
        // only when every group was upgraded.
        let allApplied = old.groups.allSatisfy { group in
            group.keys.allSatisfy { newKey in rows.contains { $0.input.serialized == newKey } }
        }
        guard allApplied else { return true }
        if let oldTag = old.joystickTag, same(preset.joysticks[0].tag, oldTag) {
            preset.joysticks[0].tag = fresh.joysticks[0].tag
        }
        if let oldNotes = old.notes, same(preset.notes, oldNotes),
           let text = ExamplePresets.presetNotes[name] {
            preset.notes = text
        }
        return true
    }

    /// True when `p` is the shipped `example` with nothing of the user's in
    /// it. Compared in full, every row setting and preset setting, except
    /// what each install fills in by itself: ids, file name, dates, order,
    /// the running flag, row notes and sections, the button family, and a
    /// folder that is the preset's own built-in one. Preset notes count as
    /// untouched when empty or the shipped text.
    /// A Keyboard Deck exactly as 1.5 shipped it: every row the same (ids,
    /// notes and sections aside) and no settings of the user's own. The
    /// retirement one-shot and a backup restore both ask.
    static func isUntouchedKeyboardDeck(_ p: Preset, builtInFolder: UUID?) -> Bool {
        guard p.name == "Keyboard Deck", p.joysticks.count == 1 else { return false }
        func withoutIDs(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, inner) in dict where key != "id" { out[key] = withoutIDs(inner) }
                return out
            }
            if let list = value as? [Any] { return list.map(withoutIDs) }
            return value
        }
        func rowSignatures(_ rows: [BindingModel]) -> [String] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let decoder = JSONDecoder()
            return rows.map { row in
                // One save-and-load round trip first, so a row built in
                // code and a row read back from disk are compared in the
                // same form.
                guard let first = try? encoder.encode(row),
                      let normalized = try? decoder.decode(BindingModel.self, from: first),
                      let data = try? encoder.encode(normalized),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      var dict = withoutIDs(object) as? [String: Any]
                else { return UUID().uuidString }   // unreadable row: never matches
                dict["note"] = nil; dict["section"] = nil
                guard let out = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
                else { return UUID().uuidString }
                return String(decoding: out, as: UTF8.self)
            }.sorted()
        }
        let shipped = rowSignatures(ExamplePresets.retiredKeyboardDeckRows)
        // The notes 1.5 shipped with it, which an earlier one-shot filled in.
        let shippedNotes = "The Mac's own keyboard as an input. F13 opens Mission Control, F14 Spotlight, F15 plays or pauses, F16 opens the screenshot menu, F17 Launchpad, F18 starts dictation, F19 locks the screen.\n\nThose seven keys are on every full-size keyboard and nothing in macOS uses them, so this preset never takes a key away from you: InputConfig listens alongside macOS, it does not replace what a key does. Scan any row and press the key you would rather use. Needs the Accessibility permission the app asks for."
        // Untouched at the preset level as well: a copy given its own
        // hotkey, auto-switch apps or other automation, a light color or
        // brightness, its own notes or descriptions, zones, a drive setup,
        // a group pinned to one keyboard or set to another kind of input,
        // or moved to another folder is the user's.
        func untouchedSettings(_ p: Preset) -> Bool {
            let notes = p.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let group = p.joysticks[0]
            return p.activateHotKey == nil
                && p.automation == PresetAutomation()
                && p.lightBarColor == nil
                && p.lightBarBrightness == nil
                && p.lightBarRainbow == nil
                && (notes.isEmpty || notes == shippedNotes)
                && (p.tag.isEmpty || p.tag == "F13 to F19 run the Mac")
                && (group.tag.isEmpty || group.tag == "The Mac's keyboard: seven spare function keys, each a system function")
                && group.customName == nil
                && group.inputKind == .auto
                && p.touchpadRegions.isEmpty && p.cursorRegions.isEmpty && p.stickRegions.isEmpty
                && p.driveConfig == nil
                && (p.groupID == nil || p.groupID == builtInFolder)
        }
        return rowSignatures(p.joysticks[0].bindings) == shipped && untouchedSettings(p)
    }

    /// Row notes, section names and the Buttons picker as this app set
    /// them. matchesShipped leaves these out (1.6 reworded them), so a
    /// restore checks them too: a copy with the user's own notes, section
    /// names or face letters is theirs, not "already here".
    /// Swaps buttons 0 with 1 and 2 with 3 in every group whose rows were
    /// scanned from a Switch Pro Controller or Joy-Con pair (see the
    /// one-shot that calls it). Returns true when anything changed.
    static func swapNintendoFaceRows(_ preset: inout Preset) -> Bool {
        func swapped(_ e: InputEvent) -> InputEvent {
            guard e.type == .button, (0...3).contains(e.index) else { return e }
            var out = e
            out.index = [1, 0, 3, 2][e.index]
            return out
        }
        var changed = false
        for g in preset.joysticks.indices {
            let print = (preset.joysticks[g].deviceFingerprint ?? "").lowercased()
            guard print.hasPrefix("gc:"), print.contains("pro controller") || print.contains("joy-con") else { continue }
            for r in preset.joysticks[g].bindings.indices {
                let row = preset.joysticks[g].bindings[r]
                let input = swapped(row.input)
                let mods = row.modifiers.map(swapped)
                if input != row.input || mods != row.modifiers {
                    preset.joysticks[g].bindings[r].input = input
                    preset.joysticks[g].bindings[r].setModifiers(mods)
                    changed = true
                }
            }
        }
        return changed
    }

    static func userTextUntouched(_ p: Preset, as example: Preset) -> Bool {
        // Automatic and no choice mean the same.
        let family = p.buttonFamily == .automatic ? nil : p.buttonFamily
        if family != ExamplePresets.buttonFamilies[p.name] { return false }
        // A controller chosen for a group, or a description written, is the
        // user's (matchesShipped leaves both out).
        if p.joysticks.contains(where: { $0.controllerModel != nil }) { return false }
        let old = ExamplePresets.tags15[p.name]
        if p.tag != example.tag && p.tag != old?.preset { return false }
        let groupTags = p.joysticks.map(\.tag)
        if groupTags != example.joysticks.map(\.tag) && groupTags != old?.groups { return false }
        var shipped = example
        ExamplePresets.fillShippedNotes(&shipped)
        ExamplePresets.fillShippedSections(&shipped)
        var sectionFor: [String: String] = [:]
        var noteFor: [String: String] = [:]
        for row in shipped.joysticks.flatMap(\.bindings) {
            if let s = row.section, !s.isEmpty { sectionFor[row.input.serialized] = s }
            // Notes set in the preset's own code count as shipped, as do
            // the ones filled in from the notes table.
            if let n = row.note, !n.isEmpty { noteFor[row.input.serialized] = n }
        }
        let notes15 = ExamplePresets.rowNotes15[p.name] ?? [:]
        for row in p.joysticks.flatMap(\.bindings) {
            let key = row.input.serialized
            let note = (row.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, note != noteFor[key], note != notes15[key] { return false }
            // The heading the standard grouping gives counts as shipped too:
            // 1.5 filed every built-in that way, the Steam ones included.
            if let s = row.section, !s.isEmpty, s != sectionFor[key], s != ControllerScaffold.section(for: row.input) {
                return false
            }
        }
        return true
    }

    /// Presets made before 1.6, for the row check: a custom preset's every
    /// row, and in an edited built-in only the rows the user changed or
    /// added (a row exactly as shipped is numbered as 1.6 reads it). An
    /// untouched built-in has nothing to offer.
    static func rememberOlderRows(_ presets: [Preset]) {
        func sig(_ b: BindingModel) -> String {
            b.input.serialized + "|" + b.outputs.map(\.displayName).joined(separator: "+")
        }
        var older: [Preset] = []
        for p in presets {
            guard let example = ExamplePresets.all.first(where: { $0.name == p.name }) else { older.append(p); continue }
            if matchesShipped(p, example, builtInFolder: p.groupID) { continue }
            let shippedRows = Set(example.joysticks.flatMap(\.bindings).map(sig))
            var q = p
            for g in q.joysticks.indices { q.joysticks[g].bindings.removeAll { shippedRows.contains(sig($0)) } }
            if q.joysticks.contains(where: { !$0.bindings.isEmpty }) { older.append(q) }
        }
        LegacyRowCheck.rememberOlder(older)
    }

    static func matchesShipped(_ p: Preset, _ example: Preset, builtInFolder: UUID?) -> Bool {
        if let g = p.groupID, g != builtInFolder { return false }
        let notes = p.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Notes this app wrote, in 1.6 or an earlier version, count as
        // untouched: 1.6 rewrote the text of a dozen built-ins, and their
        // untouched 1.5 copies came back "(from backup)".
        if !notes.isEmpty, !ExamplePresets.isShippedNotes(notes, for: p.name) { return false }
        guard let a = comparable(p), let b = comparable(example) else { return false }
        return a == b
    }

    private static func comparable(_ p: Preset) -> NSDictionary? {
        let ignored: Set<String> = ["id", "filename", "isActive", "createdAt", "modifiedAt", "sortOrder",
                                    // A collapsed group is view state, as in the editor.
                                    "isExpanded",
                                    "formatVersion", "groupID", "notes", "note", "section", "buttonFamily",
                                    // What Automatic in the Controller menu puts back.
                                    "familyBeforeModel",
                                    // The Live Visualizer's controller choice for a group.
                                    "controllerModel",
                                    // A device's slot description, which 1.6 also reworded.
                                    "tag"]
        func strip(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, inner) in dict where !ignored.contains(key) { out[key] = strip(inner) }
                // Row order is not the user's doing here: one-shots append
                // rows, so rows compare as a set.
                if let rows = out["bindings"] as? [Any] {
                    func key(_ row: Any) -> String {
                        (try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys))
                            .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    }
                    out["bindings"] = rows.sorted { key($0) < key($1) }
                }
                return out
            }
            if let list = value as? [Any] { return list.map(strip) }
            return value
        }
        // One save-and-load round trip first, so a preset built in code and
        // one read back from disk are compared in the same form.
        let encoder = JSONEncoder()
        guard let first = try? encoder.encode(p),
              let normalized = try? JSONDecoder().decode(Preset.self, from: first),
              let data = try? encoder.encode(normalized),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = strip(object) as? [String: Any] else { return nil }
        return dict as NSDictionary
    }

    /// A preset's rows as input and output text, for telling an untouched
    /// built-in copy from an edited one. Used by the tests.
    static func layoutSignature(_ p: Preset) -> [String] {
        p.joysticks.flatMap { group in
            group.bindings.map { $0.input.serialized + "=" + $0.outputs.map(\.serialized).joined(separator: "|") }
        }.sorted()
    }

    /// Restore presets, folders, and trash from a backup.
    ///
    /// Built-in folders are matched by name, since every install seeds
    /// them under fresh ids; restoring onto a new Mac used to add a second
    /// copy of every built-in folder and preset. A built-in preset that is
    /// still exactly as shipped on this Mac is replaced by the backup's
    /// copy when that copy was edited, and kept when it was not. User
    /// presets and folders already here (same id) are left alone.
    /// `madeBy16`: the backup came from 1.6 or later, so its presets already
    /// have the 1.6 changes, and a row matching 1.5 is one the user set back.
    func restoreFromBackup(presets incoming: [Preset], groups incomingGroups: [PresetGroup],
                           trash: [TrashSnapshot], madeBy16: Bool = false,
                           source16Since: Date? = nil) -> RestoreSummary {
        var summary = RestoreSummary()
        var groupMap: [UUID: UUID] = [:]
        var addedGroupIDs: [UUID] = []
        for group in incomingGroups {
            if groups.contains(where: { $0.id == group.id }) { continue }
            if group.isBuiltIn,
               let local = groups.first(where: { $0.isBuiltIn && $0.name == group.name }) {
                groupMap[group.id] = local.id
                continue
            }
            upsertGroup(group)
            addedGroupIDs.append(group.id)
            summary.groupsAdded += 1
        }
        // A restored folder whose parent was a mapped built-in follows it.
        for id in addedGroupIDs {
            if let i = groups.firstIndex(where: { $0.id == id }),
               let parent = groups[i].parentID, let mapped = groupMap[parent] {
                groups[i].parentID = mapped
            }
        }
        // A backup's folder whose parent is not in the library or the backup.
        if !addedGroupIDs.isEmpty { repairGroups(); saveGroups() }

        var shipped: [String: Preset] = [:]
        for example in ExamplePresets.all where shipped[example.name] == nil {
            shipped[example.name] = example
        }
        // The built-in folder a shipped preset belongs in, on this Mac.
        func builtInFolder(for name: String) -> UUID? {
            guard let folder = ExamplePresets.groupAssignments[name] else { return nil }
            return groups.first(where: { $0.isBuiltIn && $0.name == folder })?.id
        }
        func untouched(_ p: Preset, as example: Preset) -> Bool {
            Self.matchesShipped(p, example, builtInFolder: builtInFolder(for: example.name))
        }
        // The backup's copy: also its row notes, sections and face letters.
        func incomingUntouched(_ p: Preset, as example: Preset) -> Bool {
            untouched(p, as: example) && Self.userTextUntouched(p, as: example)
        }
        let desktopFolder = groups.first(where: { $0.isBuiltIn && $0.name == ExamplePresets.GroupName.desktop })?.id
        var toAdd: [Preset] = []
        var restoredFromBefore16: [Preset] = []
        defer { Self.rememberOlderRows(restoredFromBefore16) }
        for var preset in incoming {
            if presets.contains(where: { $0.id == preset.id }) {
                summary.presetsSkipped += 1
                continue
            }
            if let gid = preset.groupID, let mapped = groupMap[gid] { preset.groupID = mapped }
            // Keyboard Deck is retired in 1.6: a backup's untouched copy goes
            // to the Trash, as the in-place update does, by the same test
            // (whole rows and its settings). An edited one is kept. One
            // already in the Trash stays there.
            // A 1.6 backup's Keyboard Deck is one the user kept (or put back).
            if !madeBy16, Self.isUntouchedKeyboardDeck(preset, builtInFolder: desktopFolder) {
                if recentlyDeleted.contains(where: { $0.preset.id == preset.id }) {
                    summary.presetsSkipped += 1
                } else {
                    // Untrusted file: a safe name, as every other restore path.
                    preset.filename = Preset.generateFilename()
                    preset.isActive = false
                    restoreTrashFromBackup(preset: preset, deletedAt: Date())
                    summary.trashAdded += 1
                }
                continue
            }
            // The 1.6 fixes to built-ins, on rows still exactly as 1.5
            // shipped them: an edited 1.5 copy came back with side buttons
            // that did nothing, though the same copy upgraded in place got
            // the fix. Not on a 1.6 backup, whose rows already have them: a
            // row the user set back to the 1.5 value was flipped again.
            if !madeBy16 {
                preset = Self.upgradedFrom15(preset)
                ExamplePresets.fillButtonFamily(&preset)
                // Switch rows scanned before 1.6 numbered the face buttons
                // by letter (see swapNintendoFaceRows).
                if shipped[preset.name] == nil {
                    _ = Self.swapNintendoFaceRows(&preset)
                }
                // Descriptions 1.5 shipped get the 1.6 wording, and the row
                // check gets a custom preset's rows and an edited built-in's
                // changed ones (rememberOlderRows sorts them by name).
                Self.refreshShippedTags(&preset)
                restoredFromBefore16.append(preset)
            }
            // A backup from an earlier 1.6 build: the Steam presets were on
            // the Xbox names then.
            if preset.buttonFamily == .xbox, ExamplePresets.buttonFamilies[preset.name]?.isSteam == true {
                preset.buttonFamily = ExamplePresets.buttonFamilies[preset.name]
            }
            if ExamplePresets.familiedIn16v3.contains(preset.name) { ExamplePresets.fillButtonFamily(&preset) }
            // Only for a backup from before 1.6: a 1.6 copy on Auto-detect
            // was set that way by its owner.
            if !madeBy16 {
                ExamplePresets.fillSteamTarget(&preset)
                ExamplePresets.refreshSteamSections(&preset)
                // Now that a Steam copy has its target, its notes and the
                // row notes 1.5 wrote can match, as in an in-place upgrade.
                Self.refreshShippedNotes(&preset)
                Self.refreshShippedRowNotes(&preset)
            }
            if let example = shipped[preset.name],
               let local = presets.first(where: { $0.name == preset.name && untouched($0, as: example) }) {
                // Untouched as shipped now, or as 1.5 shipped it (a 1.5
                // backup on 1.6): the 1.6 upgrades make it match. Untouched
                // means the whole preset, not only its rows' main outputs: a
                // copy whose hotkey, auto-switch apps, light, notes, folder,
                // deadzones, hold or double tap were changed is the user's
                // and was being thrown away here.
                if incomingUntouched(preset, as: example)
                    || (!madeBy16 && incomingUntouched(Self.upgradedFrom15(preset), as: example)) {
                    summary.presetsSkipped += 1   // both untouched: keep this Mac's copy
                    summary.idMap[preset.id] = local.id
                    continue
                }
                // The backup's copy differs from this Mac's untouched one.
                // It may be the user's edit, or an older version's built-in
                // (a 1.5 backup on 1.6): both are kept, nothing is deleted on
                // a guess, and the backup's copy is named so.
                preset.name += " (from backup)"
                summary.builtInsReplaced += 1
            }
            // Coming back from the backup while still in Recently Deleted:
            // the trash entry goes, or Put Back and Delete Permanently later
            // acted on the live copy (overwriting it, or wiping its history).
            // Only for a copy that is restored; a skipped one keeps its
            // Trash entry.
            if let trashed = recentlyDeleted.first(where: { $0.preset.id == preset.id }) {
                recentlyDeleted.removeAll { $0.id == trashed.id }
                try? FileManager.default.removeItem(at: trashDirectory.appendingPathComponent(trashed.preset.filename))
            }
            toAdd.append(preset)
            if !preset.automation.launchAppPath.isEmpty || !preset.automation.launchURL.isEmpty
                || !(preset.automation.autoActivateBundleIDs ?? []).isEmpty || !preset.automationOutputs.isEmpty {
                summary.withOpeners.append(preset.name)
            }
        }
        for var preset in toAdd {
            // Activate Preset targets that named a skipped duplicate follow
            // it to the copy that was kept.
            for g in preset.joysticks.indices {
                for r in preset.joysticks[g].bindings.indices {
                    func remap(_ list: [OutputAction]) -> [OutputAction] {
                        list.map { o in
                            var o = o
                            if let t = o.targetPresetID, let mapped = summary.idMap[t] { o.targetPresetID = mapped }
                            return o
                        }
                    }
                    var row = preset.joysticks[g].bindings[r]
                    row.outputs = remap(row.outputs)
                    row.holdOutputs = row.holdOutputs.map(remap)
                    row.doubleTapOutputs = row.doubleTapOutputs.map(remap)
                    preset.joysticks[g].bindings[r] = row
                }
            }
            // Untrusted file: a safe on-disk name, never marked running, no
            // shortcut that clashes, and out-of-range values clamped.
            preset.filename = Preset.generateFilename()
            preset.isActive = false
            preset = preset.clampedValues()
            // Against other presets only; the Emergency Stop is checked
            // once the backup's own stop chord is restored.
            clearConflictingHotKey(&preset, againstStop: false)
            savePreset(preset)
            summary.presetsAdded += 1
        }
        for snap in trash {
            // An id already in the library or the trash is skipped: Put
            // Back would otherwise overwrite the live preset with it.
            if presets.contains(where: { $0.id == snap.preset.id }) { continue }
            if recentlyDeleted.contains(where: { $0.preset.id == snap.preset.id }) { continue }
            if deletedFolders.contains(where: { $0.presets.contains { $0.id == snap.preset.id } }) { continue }
            var p = snap.preset
            p.filename = Preset.generateFilename()
            p.isActive = false
            restoreTrashFromBackup(preset: p, deletedAt: snap.deletedAt)
            // Sorted by its own history, not this Mac's dates: from a 1.5
            // backup it is owed the 1.6 upgrades; from a 1.6 backup, only if
            // it was deleted before 1.6 first ran on the Mac that made it.
            if !madeBy16 {
                Self.markTrash(p.id, key: Self.trashBefore16Key)
            } else if source16Since.map({ snap.deletedAt >= $0 }) ?? true {
                Self.markTrash(p.id, key: Self.trashFrom16Key)
            } else {
                Self.markTrash(p.id, key: Self.trashBefore16Key)
            }
            summary.trashAdded += 1
        }
        return summary
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
        // A deleted folder's presets too, each as its own Recently Deleted
        // entry: they were missing from backups, so restoring on a new Mac
        // lost them though single deleted presets came back.
        recentlyDeleted.map { TrashSnapshot(preset: $0.preset, deletedAt: $0.deletedAt) }
            + deletedFolders.flatMap { folder in
                folder.presets.map { TrashSnapshot(preset: $0, deletedAt: folder.deletedAt) }
            }
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
        pruneTrash()
        loadDeletedFolders()
    }

    func duplicatePreset(_ preset: Preset) -> Preset {
        // Copy ALL fields (light, notes, automation, groupID, cursor flags, ...)
        // and override only what a duplicate must change. id is immutable, so
        // mint a fresh one via a Codable round-trip, the technique revertPreset
        // also uses. The old memberwise init dropped every field it did not list.
        var copy = preset
        copy.name = "\(preset.name) (Copy)"
        copy.filename = Preset.generateFilename()
        copy.isActive = false
        // Not its shortcut or its auto-switch apps: the copy, first in the
        // list, took both over from the original until the next launch.
        copy.activateHotKey = nil
        copy.automation.autoActivateBundleIDs = nil
        if let data = try? JSONEncoder().encode(copy),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dict["id"] = UUID().uuidString
            if let patched = try? JSONSerialization.data(withJSONObject: dict),
               let final = try? JSONDecoder().decode(Preset.self, from: patched) {
                savePreset(final)
                return final
            }
        }
        // Fallback (round-trip failed): the init mints a fresh id, but cannot
        // carry the fields it does not list.
        let fallback = Preset(name: copy.name, tag: copy.tag, joysticks: copy.joysticks,
                              filename: copy.filename, isActive: false, groupID: copy.groupID)
        savePreset(fallback)
        return fallback
    }

    // MARK: - Reordering

    func movePresets(from source: IndexSet, to destination: Int) {
        let valid = IndexSet(source.filter { $0 >= 0 && $0 < presets.count })
        guard !valid.isEmpty else { return }
        presets.move(fromOffsets: valid, toOffset: min(max(destination, 0), presets.count))
    }

    // MARK: - Activation

    func activatePreset(_ preset: Preset) {
        // Suppress the "deactivated" announcement so a preset switch only
        // announces the activation, not both halves of the swap.
        deactivateAll(announce: false)
        activePresetId = preset.id
        lastActivatedPresetId = preset.id
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index].isActive = true
        }
        // Persist active preset to the recovery sentinel so a crash here
        // doesn't lose the user's place. Called synchronously (not in a
        // detached Task) so deactivateAll's nil above and this preset.id record
        // in deterministic order; two unstructured Tasks could reorder and
        // leave the sentinel stuck at nil while a preset is actually active.
        CrashRecoveryService.shared.recordActivePreset(preset.id)
        // Said honestly when Accessibility is off: the preset runs, but
        // macOS drops its keys and clicks.
        if preset.needsAccessibility && !AccessibilityPermissionService.shared.isTrusted {
            AccessibilityNotification.Announcement("\(preset.name) started, but Accessibility is off, so its keys and clicks are blocked").post()
        } else {
            AccessibilityNotification.Announcement("Activated preset \(preset.name)").post()
        }
    }

    func deactivateAll(announce: Bool = true) {
        let wasActive = activePresetId != nil
        activePresetId = nil
        // Only rewrite presets that are actually active. Writing isActive=false
        // on every preset copy-on-write-copied the whole library on each switch;
        // in practice at most one preset is active.
        for i in presets.indices where presets[i].isActive {
            presets[i].isActive = false
        }
        CrashRecoveryService.shared.recordActivePreset(nil)
        if announce && wasActive {
            AccessibilityNotification.Announcement("Presets deactivated").post()
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
        /// Said on the row when part of the file could not be read.
        var warning: String? = nil
        /// Remove outputs that open apps, URLs, or Shortcuts on import. On
        /// by default: a shared file should not open things on a first press
        /// before its new owner has looked at it.
        var removeOpeners = true
        /// Turn off hiding, confining and recentering the pointer, the
        /// speed multipliers and drive mode on import. On by default for
        /// the same reason: they act on the whole Mac once started.
        var removePointerSettings = true

        /// What import leaves out that the file carries (its keyboard
        /// shortcut, the apps that switch to it, the app or website it opens
        /// when started), said on the review row so none of it goes quietly.
        var droppedLine: String? {
            guard let p = preset else { return nil }
            var parts: [String] = []
            if let hotKey = p.activateHotKey { parts.append("its keyboard shortcut (\(hotKey.displayString))") }
            let apps = p.automation.autoActivateBundleIDs?.count ?? 0
            if apps > 0 {
                parts.append(apps == 1 ? "switching to it when its app comes to the front"
                             : "switching to it when its \(apps) apps come to the front")
            }
            if !p.automation.launchAppPath.isEmpty || !p.automation.launchURL.isEmpty {
                parts.append("the app or website it opens when started")
            }
            guard !parts.isEmpty else { return nil }
            let list = parts.count == 1 ? parts[0]
                : parts.dropLast().joined(separator: ", ") + (parts.count > 2 ? "," : "") + " and " + parts[parts.count - 1]
            return "Not brought in: \(list). Set them again in the preset if you want them."
        }

        /// One line per output that opens something or types text, for the
        /// review row.
        /// Every one of them in full, then the Lock Screen and preset
        /// switching outputs, then every macro with all of its steps, so
        /// nothing a shared preset does is left off the review.
        var automationLines: [String] {
            guard let p = preset else { return [] }
            return PresetStore.reviewLines(for: p)
        }
        var hasOpeners: Bool {
            guard let p = preset else { return false }
            return p.automationOutputs.contains(where: \.opensSomething) || p.hasSpotlightChord
        }
        var pointerLine: String? { preset?.importPointerLine }
    }

    nonisolated static func reviewLines(for p: Preset) -> [String] {
        var lines = p.automationOutputs.map(\.importReviewLine)
        if p.hasSpotlightChord { lines.append("Opens Spotlight with Command Space") }
        lines += p.allOutputs.filter(\.isNotableOnImport).map(\.importReviewLine)
        lines += p.importMacroLines
        return lines
    }

    // MARK: - Imported presets not yet started

    /// Imported presets that have never been started. The first start asks
    /// first and says what the preset does, so a shared file cannot type or
    /// open things on its first press without its new owner having looked.
    static let unreviewedKey = "InputConfig.unreviewedImports"

    func markUnreviewedImport(_ id: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: Self.unreviewedKey) ?? [])
        ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: Self.unreviewedKey)
    }

    func isUnreviewedImport(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.unreviewedKey) ?? []).contains(id.uuidString)
    }

    func markReviewed(_ id: UUID) {
        let ids = (UserDefaults.standard.stringArray(forKey: Self.unreviewedKey) ?? []).filter { $0 != id.uuidString }
        UserDefaults.standard.set(ids, forKey: Self.unreviewedKey)
    }

    /// Asks before an imported preset's first start. True to go ahead.
    /// Started by something other than the person at the Mac (a controller
    /// button, a hotkey), it does not start and the log says why.
    func confirmFirstStart(_ preset: Preset, background: Bool) -> Bool {
        guard isUnreviewedImport(preset.id) else { return true }
        guard !background else {
            ActivityLog.shared.warning("Presets", "\(preset.name) was imported and has not been started yet; start it from its page once to confirm it")
            return false
        }
        let lines = Self.reviewLines(for: preset) + [preset.importPointerLine].compactMap { $0 }
        let alert = NSAlert()
        alert.messageText = "Start \(preset.name)?"
        alert.informativeText = "You imported this preset and have not started it before. "
            + (lines.isEmpty ? "It sends keys and clicks from its rows; nothing in it opens apps, websites or Shortcuts, or types text."
               : "Besides its keys and clicks, it does this:\n\n" + lines.prefix(12).joined(separator: "\n")
                 + (lines.count > 12 ? "\nand \(lines.count - 12) more; open it in the editor to see them all." : ""))
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        markReviewed(preset.id)
        return true
    }

    /// Sheet-driven state: a non-empty array opens the review sheet.
    /// Reset to empty on dismiss / cancel / completion.
    @Published var importReviewQueue: [ImportPreview] = []

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
            func failed(_ message: String) {
                previews.append(ImportPreview(url: url, filename: filename, nameDraft: baseName,
                                              preset: nil, errorMessage: message))
            }
            // A preset file is a few hundred kilobytes at most; anything
            // far larger is not one, and reading it would stall the app.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxImportBytes else {
                failed("This file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), too large to be a preset.")
                continue
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                failed("Couldn't read file: \(error.localizedDescription)")
                continue
            }
            // A whole-library backup is restored in Settings, not imported
            // as a preset.
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               object["schemaVersion"] != nil, object["presets"] is [Any] {
                failed("This is a whole InputConfig backup, not a preset. A backup replaces settings and adds presets without review, so restore only one you made yourself, in Settings, Advanced, Restore from Backup.")
                continue
            }
            // Try modern Preset codable shape first.
            JoystickMapping.droppedRowsDuringDecode = 0
            JoystickMapping.keptRowsDuringDecode = 0
            do {
                var preset = try JSONDecoder().decode(Preset.self, from: data)
                preset.filename = Preset.generateFilename()
                var preview = ImportPreview(url: url, filename: filename,
                                            nameDraft: preset.name.isEmpty ? baseName : preset.name,
                                            preset: preset, errorMessage: nil)
                let unreadable = JoystickMapping.droppedRowsDuringDecode + JoystickMapping.keptRowsDuringDecode
                    + preset.unreadableJoysticks.count
                let readable = preset.joysticks.reduce(0) { $0 + $1.bindings.count }
                if unreadable > 0 && readable == 0 {
                    preview.preset = nil
                    preview.errorMessage = "None of this file's rows could be read. It may come from a newer version of InputConfig, or it is missing fields such as row ids."
                } else if unreadable > 0 {
                    preview.warning = "\(unreadable) row\(unreadable == 1 ? "" : "s") could not be read (made by a newer version of InputConfig, or edited by hand) and are left out of the import."
                }
                previews.append(preview)
                continue
            } catch let decodeError {
                // Try legacy text-based preset format before giving up.
                if var legacy = Preset.fromLegacyJSON(data, filename: Preset.generateFilename()) {
                    legacy.filename = Preset.generateFilename()
                    previews.append(ImportPreview(url: url, filename: filename,
                                                  nameDraft: legacy.name.isEmpty ? baseName : legacy.name,
                                                  preset: legacy, errorMessage: nil))
                    continue
                }
                let isSyntaxError: Bool
                if let de = decodeError as? DecodingError, case .dataCorrupted = de {
                    isSyntaxError = true
                } else {
                    isSyntaxError = false
                }
                failed(isSyntaxError
                       ? "Invalid JSON. Open the file in a text editor and check for missing braces, quotes, or commas."
                       : "JSON doesn't match the preset schema (\(describe(decodeError))). The file may be from an unsupported app version.")
            }
        }
        JoystickMapping.droppedRowsDuringDecode = 0
        JoystickMapping.keptRowsDuringDecode = 0
        // A second batch while the sheet is open joins the first instead
        // of replacing it unseen.
        importReviewQueue += previews
    }

    /// Largest file the importer will read.
    static let maxImportBytes = 5 * 1024 * 1024

    /// Commit the user's reviewed selections. Each importable preview is
    /// saved under a fresh identity, made safe for the library (see
    /// `Preset.sanitizedForImport`). Returns the new presets' ids, in order,
    /// so the sidebar can select the first.
    @discardableResult
    func commitImportPreviews(_ previews: [ImportPreview]) -> [UUID] {
        var saved: [UUID] = []
        for preview in previews {
            guard let parsed = preview.preset else { continue }
            // Fresh identity, so an import can never overwrite (and then
            // lose on next launch) a local preset sharing the decoded id.
            var preset = parsed.withNewIdentity().sanitizedForImport(removingOpeners: preview.removeOpeners,
                                                                                removingPointerSettings: preview.removePointerSettings)
            // A file written before 1.6: the same upgrades the library got,
            // and its Switch and 8BitDo rows offered the fix when that pad
            // connects.
            let older = parsed.writtenByFormatVersion < 2
            if older { preset = Self.upgradedFrom15(preset) }
            let trimmed = preview.nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { preset.name = trimmed }
            clearConflictingHotKey(&preset)
            savePreset(preset)
            markUnreviewedImport(preset.id)
            if older { Self.rememberOlderRows([preset]) }
            saved.append(preset.id)
        }
        importReviewQueue.removeAll { done in previews.contains { $0.id == done.id } }
        return saved
    }

    /// An imported or restored preset's shortcut is dropped when another
    /// preset or the Emergency Stop already uses it: it would take that
    /// shortcut over, and the Emergency Stop must always stop.
    private func clearConflictingHotKey(_ preset: inout Preset, againstStop: Bool = true) {
        guard let key = preset.activateHotKey else { return }
        let stop = EmergencyStopService.shared
        if presets.contains(where: { $0.id != preset.id && $0.activateHotKey == key })
            || (againstStop && stop.isEnabled && stop.spec == key) {
            preset.activateHotKey = nil
        }
    }

    /// Take a preset's shortcut away when it is the Emergency Stop's chord.
    /// Run after a backup restore set the stop chord.
    func clearHotKeysClaimedByEmergencyStop() {
        let stop = EmergencyStopService.shared
        guard stop.isEnabled else { return }
        for i in presets.indices where presets[i].activateHotKey == stop.spec {
            presets[i].activateHotKey = nil
            savePresetToDisk(presets[i])
            ActivityLog.shared.warning("Presets", "\(presets[i].name) lost its shortcut: the restored Emergency Stop uses the same keys")
        }
        // Let go of those chords now, so the stop can take its chord at once.
        PresetHotKeyService.shared.sync(with: presets)
    }

    /// Discard the pending review without saving anything.
    func cancelImportReview() {
        importReviewQueue = []
    }

    func exportPresetToFile(_ preset: Preset, to url: URL) {
        // Lossless native encode (matching Share), NOT the legacy string form.
        // toLegacyJSON serializes only input->output tokens and silently drops
        // deadzones, curves, macros, haptics, and the entire driveConfig, so an
        // exported "backup" quietly lost the user's real configuration. Import
        // decodes native Preset JSON first (falling back to legacy), so this
        // round-trips cleanly.
        // Device fingerprints stay on this Mac.
        var copy = preset
        for g in copy.joysticks.indices { copy.joysticks[g].deviceFingerprint = nil }
        if let data = try? JSONEncoder().encode(copy) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Conversion

    func convertPreset(_ preset: Preset, from source: ControllerType, to destination: ControllerType) -> Preset {
        // A new preset beside the original. Keeping the id made the copy
        // replace the original in the library and left its file orphaned.
        var converted = ControllerType.convert(preset: preset, from: source, to: destination).withNewIdentity()
        // A new preset beside the original: the shortcut and auto-switch
        // apps stay with the original.
        converted.activateHotKey = nil
        converted.automation.autoActivateBundleIDs = nil
        converted.name = "\(preset.name) (\(destination.rawValue))"
        converted.sortOrder = nil
        // Rows moved to the other pad's positions are named that pad's way.
        if converted.buttonFamily != nil { converted.buttonFamily = destination.buttonFamily }
        savePreset(converted)
        return converted
    }
}
