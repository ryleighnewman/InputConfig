import SwiftUI
import SceneKit
import Metal
import GameController
import UniformTypeIdentifiers

// ContentView, the sidebar, its folders and its commands. Split from ContentView.swift, where the type
// and its state live, so a Debug build type-checks it in parallel with the rest.

extension ContentView {
    var sidebarView: some View {
        VStack(spacing: 0) {
            let _ = LaunchSignpost.once("Sidebar.body")
            controllerStatusBar
                // Picking a preset moves the highlight off the folder.
                .onChange(of: selectedPresetId) { _, _ in selectedFolderID = nil }
                // The Presets menu's actions on the selection.
                .onReceive(NotificationCenter.default.publisher(for: .inputConfigSidebarCommand)) { note in
                    if let command = note.object as? SidebarCommand { handleSidebarCommand(command) }
                }
                // Move to Folder from the Presets menu, for anyone who cannot
                // open a row's own menu.
                .sheet(isPresented: $showingTrashSheet) {
                    TrashSheet(store: presetStore, close: { showingTrashSheet = false },
                               restored: { id in revealPreset(id) })
                }
                .sheet(item: $sidebarMoveTarget) { target in
                    SidebarMoveSheet(target: target, store: presetStore,
                                     choices: moveChoices(for: target),
                                     close: { sidebarMoveTarget = nil },
                                     moved: { target in
                                         switch target {
                                         case .preset(let id): revealPreset(id)
                                         case .folder(let id):
                                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                 NotificationCenter.default.post(name: .inputConfigScrollToPreset, object: id)
                                             }
                                         }
                                     })
                }

            sidebarSearchRow

            ScrollViewReader { proxy in
            List(selection: selectedPresetIdBinding) {
                // The presets and folders, made again only when something
                // they show changed: a switch leaves them to their own
                // selection state (see SidebarRows).
                SidebarRows(key: sidebarRowsKey) { sidebarRowsContent }

                // Trash - shown only when there's something in it. Each
                // entry has Restore + Permanently Delete actions. No TTL -
                // entries persist on disk until the user acts on them.
                if !presetStore.recentlyDeleted.isEmpty || !presetStore.deletedFolders.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showingTrashDisclosure) {
                            ForEach(presetStore.deletedFolders) { entry in
                                trashFolderRow(entry: entry)
                                    .selectionDisabled()
                            }
                            ForEach(presetStore.recentlyDeleted) { entry in
                                trashRow(entry: entry)
                                    .selectionDisabled()
                            }
                            Button {
                                confirmingEmptyTrash = true
                            } label: {
                                Label("Empty Trash", systemImage: "trash.slash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.solidSecondaryCompact)
                            .padding(.top, 4)
                            .selectionDisabled()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.orange)
                                Text("Trash (\(presetStore.recentlyDeleted.count + presetStore.deletedFolders.count))")
                                    .font(.caption.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            // A selection-disabled row does not toggle its
                            // disclosure on a label click, so the label does.
                            .background(SidebarClickTarget {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showingTrashDisclosure.toggle()
                                }
                            })
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { showingTrashDisclosure.toggle() }
                        }
                        // The trash is not a preset: clicking it must not
                        // clear the selection and bounce the window to the
                        // home screen.
                        .selectionDisabled()
                        .id(Self.trashSectionID)
                    }
                }
            }
            .listStyle(.sidebar)
            // The list's disclosure chevrons sit at a fixed column the row
            // insets cannot move, so the whole list steps in 12 pt: the
            // folder outlines then sit 20 pt from the window edge, matching
            // their distance to the panel's divider on the right, with the
            // chevrons inside them.
            .padding(.leading, 20)
            // The same 20 points on the right: to the scroll bar when the
            // system keeps one (Show scroll bars: Always), else to the edge.
            // The bar stays in place rather than coming and going, so the
            // rows never move when the list grows past the window.
            .background(KeepScrollerShown())
            .scrollContentBackground(.hidden)
            // Favorites only swaps a flat list of starred presets for the
            // whole library with its folders. Diffing the same rows across
            // the two layouts left stale copies drawn over each other, so
            // switching builds a fresh list instead. Folder open states live
            // in the store and survive the rebuild.
            .id(presetStore.showFavoritesOnly && !presetStore.favoritePresets.isEmpty)
            .onReceive(NotificationCenter.default.publisher(for: .inputConfigScrollToPreset)) { note in
                // A preset or folder by its id, or the Trash by its name.
                guard let id = (note.object as? UUID).map(AnyHashable.init) ?? (note.object as? String).map(AnyHashable.init) else { return }
                // The selected preset glides there through the sidebar's own
                // table; a folder or the Trash goes through scrollTo.
                // Only a preset's id: a folder's found no anchor and made a
                // view for every sidebar row looking for one, twice a reveal.
                if let presetID = note.object as? UUID, presetStore.presets.contains(where: { $0.id == presetID }),
                   SidebarSmoothScroll.toPreset(presetID, animated: !(sidebarAppReduceMotion || sidebarSystemReduceMotion)) { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inputConfigImportedPreset)) { note in
                // Newly imported preset hint: select, scroll, flash.
                // The flash uses the same flashingPresetID state the
                // FeatureDemo "jump to preset" flow already uses, so
                // the visual treatment matches across the app.
                guard let id = note.object as? UUID else { return }
                // Shown even with Favorites only on or its folder closed.
                revealPreset(id)
                flashingPresetID = id
                if !SidebarSmoothScroll.toPreset(id, animated: !(sidebarAppReduceMotion || sidebarSystemReduceMotion)) {
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if flashingPresetID == id {
                        withAnimation(.easeOut(duration: 0.9)) { flashingPresetID = nil }
                    }
                }
            }
            } // ScrollViewReader

            bottomToolbar
        }
        .navigationTitle("Presets")
        .onAppear {
            LaunchSignpost.once("Sidebar.onAppear")
            #if DEBUG
            LaunchClock.markSidebar()
            #endif
        }
        // Wider at a large Text Size, so the bottom toolbar's + and Import fit.
        .frame(minWidth: 280 * min(max(1, editorTextScale), 1.3))
        .spotlightAnchor(SpotlightID.sidebar)
        // On the sidebar itself, not on the Trash's own button: a long
        // Trash never built that row, so the menu's Empty Trash showed
        // nothing and its flag blocked every other sheet.
        .confirmationDialog("Empty the Trash?", isPresented: $confirmingEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) {
                presetStore.emptyTrash()
                AccessibilityNotification.Announcement(String(localized: "Trash emptied")).post()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every preset and folder in it is deleted permanently.")
        }
        .sheet(item: $creatingGroupForPreset) { preset in
            newGroupSheet(for: preset)
                .glassBackground()
        }
        .sheet(item: $renamingGroup) { group in
            renameGroupSheet(for: group)
                .glassBackground()
        }
    }

    /// What the preset and folder rows read from this view, the store's
    /// publish count standing for the store. See SidebarRowsKey.
    private var sidebarRowsKey: SidebarRowsKey {
        SidebarRowsKey(storeRevision: presetStore.publishCount,
                       query: sidebarQuery,
                       selectedFolderID: selectedFolderID,
                       flashingPresetID: flashingPresetID,
                       flashingGroupID: flashingGroupID,
                       colorEditingGroupID: colorEditingGroup?.id,
                       folderPendingDelete: folderPendingDelete,
                       folderPickerColor: folderPickerColor,
                       groupPaths: groupPathChoices)
    }

    /// The search results, the favorites or the whole library. Run inside
    /// SidebarRows: any state of this view read here belongs in
    /// `sidebarRowsKey`, and the selection is read only through each row's
    /// PresetRowSelection, never `selectedPresetId`.
    @ViewBuilder
    private var sidebarRowsContent: some View {
        // Searching: every preset that matches, from every folder.
        if !sidebarQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            let found = sidebarSearchResults
            Section {
                if found.isEmpty {
                    Text("No presets match")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(found) { preset in
                    presetRow(for: preset, leadingInset: -4)
                }
            } header: {
                sidebarHeader(found.count == 1 ? "1 preset" : "\(found.count) presets")
            }
        // Favorites only: just the starred presets, switched from the
        // star in the header. Off, or with nothing starred, the whole
        // library as always.
        } else if presetStore.showFavoritesOnly && !presetStore.favoritePresets.isEmpty {
            Section {
                ForEach(presetStore.favoritePresets) { preset in
                    presetRow(for: preset, leadingInset: -4)
                }
            } header: {
                sidebarHeader("Favorites")
            }
        } else {
            librarySection
        }
    }

    /// Above the list: a search field over every preset, and how the list
    /// is sorted.
    private var sidebarSearchRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search presets", text: $sidebarQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .accessibilityLabel("Search presets")
                    .task(id: sidebarQuery) {
                        try? await Task.sleep(for: .milliseconds(600))
                        if !Task.isCancelled { announceSearchResults() }
                    }
                if !sidebarQuery.isEmpty {
                    Button {
                        sidebarQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            Menu {
                Picker("Sort by", selection: $presetStore.sidebarSort) {
                    ForEach(PresetStore.SidebarSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort presets")
            .accessibilityLabel("Sort presets")
            .accessibilityValue(presetStore.sidebarSort.title)
        }
        // On the controller icons' edge, 12 points in; the sort arrows sit
        // as far from the other edge (the menu adds about 4.5 of its own).
        .padding(.leading, 12)
        .padding(.trailing, 7.5)
        // Clear of a selected controller row's highlight above it.
        .padding(.top, 8)
        .padding(.bottom, 6)
        // The field waits for a click: focused at launch it took the keys
        // meant for the list and the app's shortcuts.
        .background(NoInitialTextFocus(focusNearestList: true).frame(width: 0, height: 0))
    }

    private var isSearching: Bool { !sidebarQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What the search found, said to VoiceOver once typing pauses.
    private func announceSearchResults() {
        guard isSearching else { return }
        let n = sidebarSearchResults.count
        AccessibilityNotification.Announcement(n == 0 ? String(localized: "No presets match")
                                               : n == 1 ? String(localized: "1 preset") : String(localized: "\(n) presets")).post()
    }

    /// Every preset whose name, tag or folder holds each typed word, in the
    /// sidebar's order.
    private var sidebarSearchResults: [Preset] { presetStore.search(sidebarQuery) }

    /// The whole library: New Preset, the user's own presets and folders,
    /// then the shipped ones.
    @ViewBuilder
    private var librarySection: some View {
        // The user's own presets first, above the shipped folders,
        // with New Preset as the first row so making one is the most
        // obvious thing in the sidebar. Always shown, even when empty.
        Section {
            Button {
                createNewPreset()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("New Preset")
                        .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                }
                // Sidebar rows sit at a minimum height and center
                // their content in it, so the row insets alone cannot
                // move the label; this pushes it down until the room
                // above matches the room below.
                .padding(.top, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: -6, bottom: 2, trailing: 18))
            .selectionDisabled()
            .accessibilityHint("Creates a preset and opens it in the editor")

            ForEach(presetStore.presets(in: nil)) { preset in
                presetRow(for: preset, leadingInset: -4)
            }
            topLevelFolders(presetStore.userTopLevelGroups, builtIn: false)

            // The shipped library, under a heading of its own. It is
            // a plain row rather than a second section header so the
            // space above and below New Preset comes out the same;
            // the list pads a section header more than it pads a
            // row. Only a heading: these are ordinary presets in the
            // user's own folder, edits stick, a preset moved out
            // stays out, and updates never rewrite them.
            // Settings, Data & storage can take the whole shipped library
            // out of the list.
            if !presetStore.hideBuiltInPresets {
                Text("Built-in Presets")
                    .font(.caption)
                    .foregroundStyle(.hint)
                    .listRowInsets(EdgeInsets(top: 0, leading: -25.5, bottom: 10, trailing: 2))
                    .selectionDisabled()
                    .accessibilityAddTraits(.isHeader)
                topLevelFolders(presetStore.builtInTopLevelGroups, builtIn: true)
            }
        } header: {
            sidebarHeader("My Presets")
        }
    }

    /// A sidebar section heading, with the Favorites only star at its right
    /// once anything is starred.
    private func sidebarHeader(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
            Spacer(minLength: 0)
            if !presetStore.favoritePresets.isEmpty {
                Button {
                    presetStore.showFavoritesOnly.toggle()
                } label: {
                    Image(systemName: presetStore.showFavoritesOnly ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(presetStore.showFavoritesOnly ? Color.yellow.opacity(0.7) : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(presetStore.showFavoritesOnly ? String(localized: "Show all presets") : String(localized: "Show favorites only"))
                .accessibilityLabel(presetStore.showFavoritesOnly ? String(localized: "Show all presets") : String(localized: "Show favorites only"))
            }
        }
        // The list sets a section heading in from its rows; this puts it on
        // the sidebar's one left edge.
        .padding(.leading, -13.5)
    }

    /// Render a folder and everything under it. Recursive: a folder's content
    /// is its child folders (each rendered by another `groupSection` call) and
    /// then its own presets, so folders can nest to any depth. Returns AnyView
    /// because an opaque `some View` can't reference itself recursively.
    func groupSection(_ group: PresetGroup, depth: Int = 0,
                              outline: FolderOutlineContext? = nil) -> AnyView {
        let presetsInGroup = presetStore.presets(in: group.id)
        let childGroups = presetStore.subgroups(of: group.id)
        // Which piece of the enclosing top-level folder's outline a row draws.
        func role(for id: AnyHashable) -> FolderOutlineRole? {
            guard let outline else { return nil }
            return outline.lastRowID == id ? .bottom : .middle
        }
        return AnyView(
            DisclosureGroup(isExpanded: groupExpandedBinding(for: group)) {
                // Nested folders first, then this folder's own presets.
                ForEach(childGroups) { sub in
                    // A nested folder header is a middle row of the top-level
                    // box, or its bottom when it is the last thing showing.
                    let subHeaderRole: FolderOutlineRole? =
                        (outline != nil && !sub.isExpanded) ? role(for: AnyHashable(sub.id))
                        : (outline != nil ? .middle : nil)
                    groupSection(sub, depth: depth + 1, outline: outline)
                        .listRowBackground(outline.map { FolderOutlineSegment(role: subHeaderRole ?? .middle, color: $0.color,
                                                                              selected: selectedFolderID == sub.id) })
                }
                ForEach(presetsInGroup) { preset in
                    presetRow(for: preset,
                              outline: outline.map { (role(for: AnyHashable(preset.id)) ?? .middle, $0.color) })
                }
                if childGroups.isEmpty && presetsInGroup.isEmpty {
                    // The placeholder closes the box only when it is the last
                    // thing showing; an empty subfolder above its parent's own
                    // presets is a middle row.
                    Text("Drop a preset here, or add a subfolder.")
                        .font(.caption2)
                        .foregroundStyle(.hint)
                        .padding(.vertical, 4)
                        .listRowBackground(outline.map {
                            FolderOutlineSegment(role: role(for: AnyHashable("empty-\(group.id.uuidString)")) ?? .middle, color: $0.color)
                        })
                }
            } label: {
                let tint = groupTintColor(for: group)
                HStack(spacing: 6) {
                    Image(systemName: tint == nil ? "folder" : "folder.fill")
                        .font(.caption)
                        // Liquid-glass folder chips: a vertical gradient of the
                        // folder's own color (bright where light would catch the
                        // top edge, deeper toward the base) rendered genuinely
                        // see-through, so the frosted sidebar reads through the
                        // icon instead of it sitting as a flat paint chip.
                        .foregroundStyle(
                            tint.map { c in
                                AnyShapeStyle(LinearGradient(
                                    colors: [c.opacity(0.95), c.opacity(0.45)],
                                    startPoint: .top, endPoint: .bottom))
                            } ?? AnyShapeStyle(.secondary)
                        )
                        .opacity(tint == nil ? 1 : 0.75)
                    Text(ShippedText.t(group.name))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                // Keep the folder icon tight to the disclosure arrow. Nesting
                // depth is already conveyed by the List's own per-level indent,
                // so no extra manual left-indent is added here.
                .padding(.leading, 2)
                .contentShape(Rectangle())
                .selectionDisabled()
                .background(SidebarClickTarget { selectedFolderID = group.id })
                // The folder commands' target, without a pointer click.
                .accessibilityAction(named: "Select Folder") {
                    selectedFolderID = group.id
                    AccessibilityNotification.Announcement(String(localized: "Folder \(ShippedText.t(group.name)) selected")).post()
                }
                .accessibilityAddTraits(selectedFolderID == group.id ? .isSelected : [])
                .contextMenu {
                    Button("Rename Folder…") {
                        // The name the sidebar shows, a built-in folder's
                        // in the app's language.
                        renameGroupName = ShippedText.t(group.name)
                        renamingGroup = group
                    }
                    Button("Folder Color…") {
                        colorEditingGroup = group
                    }
                    Button("New Subfolder…") {
                        let id = presetStore.createGroup(named: String(localized: "New Folder").withoutRTLMark, parentID: group.id)
                        presetStore.setGroupExpanded(group.id, true)
                        if let g = presetStore.groups.first(where: { $0.id == id }) {
                            renameGroupName = g.name
                            renamingGroup = g
                        }
                    }
                    if group.parentID == nil {
                        Button("Move Folder Up") { selectedFolderID = group.id; handleSidebarCommand(.folderUp) }
                        Button("Move Folder Down") { selectedFolderID = group.id; handleSidebarCommand(.folderDown) }
                    }
                    Menu("Move to Folder") {
                        Button("Top Level (no parent)") {
                            presetStore.setGroupParent(group.id, parentID: nil)
                        }
                        let targets = eligibleParentFolders(for: group)
                        if !targets.isEmpty {
                            Divider()
                            ForEach(targets) { target in
                                Button(ShippedText.t(target.name)) {
                                    presetStore.setGroupParent(group.id, parentID: target.id)
                                    presetStore.setGroupExpanded(target.id, true)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete Folder\u{2026}", role: .destructive) {
                        folderPendingDelete = group.id
                    }
                }
                .popover(isPresented: Binding(
                    get: { colorEditingGroup?.id == group.id },
                    set: { if !$0 { colorEditingGroup = nil } }
                ), arrowEdge: .trailing) {
                    folderColorPopover(for: group)
                }
                // Asked first, like deleting a single preset.
                .confirmationDialog("Delete the folder \u{201C}\(ShippedText.t(group.name))\u{201D}?",
                                    isPresented: Binding(get: { folderPendingDelete == group.id },
                                                         set: { if !$0 { folderPendingDelete = nil } }),
                                    titleVisibility: .visible) {
                    Button("Delete Folder", role: .destructive) {
                        // The engine stops before the preset goes, the way a
                        // single preset delete does; deactivateAll alone only
                        // cleared the flags and left the outputs running.
                        if presetStore.folderHoldsActivePreset(group.id) { mappingEngine.stop() }
                        presetStore.deleteGroup(group.id)
                        AccessibilityNotification.Announcement(String(localized: "\(ShippedText.t(group.name)) moved to the Trash")).post()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The folder, its subfolders and their presets move to the Trash at the bottom of the sidebar, where you can put them back. A preset in it that is running stops.")
                }
            }
            // Allow dropping presets onto this folder header to add them.
            .dropDestination(for: String.self) { items, _ in
                for item in items {
                    if let uuid = UUID(uuidString: item) {
                        presetStore.setPresetGroup(uuid, groupID: group.id)
                    }
                }
                return true
            }
        )
    }

    /// The Presets menu's actions, on the sidebar's selected preset or the
    /// selected folder (a clicked header, else the selected preset's).
    private func handleSidebarCommand(_ command: SidebarCommand) {
        // Nothing acts behind an open sheet: a second sheet cannot show, and
        // a reorder behind the editor went unseen.
        guard canPresentSheet else {
            NSSound.beep()
            AccessibilityNotification.Announcement(String(localized: "Close the open window or dialog first")).post()
            return
        }
        let preset = selectedPresetId.flatMap { id in presetStore.presets.first { $0.id == id } }
        let folderID = selectedFolderID ?? preset?.groupID
        // A built-in folder hidden by Hide built-in presets has no row, so a
        // dialog hung off it never appeared and left every sheet blocked.
        let folder = folderID.flatMap { id in presetStore.groups.first { $0.id == id } }
            .flatMap { presetStore.hideBuiltInPresets && presetStore.isInBuiltInFolder($0.id) ? nil : $0 }
        // A command with nothing to act on says so, rather than nothing.
        func refuse(_ said: String) {
            NSSound.beep()
            AccessibilityNotification.Announcement(said).post()
        }
        let noPreset = String(localized: "No preset selected")
        let noFolder = String(localized: "No folder selected. Choose Select Next Folder first.")
        switch command {
        case .duplicate: if let preset { duplicateAndAnnounce(preset) } else { refuse(noPreset) }
        case .export: if let preset { exportPreset(preset) } else { refuse(noPreset) }
        case .print: if let preset { PresetPrint.run(preset, controllers: controllerService) } else { refuse(noPreset) }
        case .favorite: if let preset { toggleFavoriteAndAnnounce(preset) } else { refuse(noPreset) }
        case .delete: if let preset { confirmDelete(preset) } else { refuse(noPreset) }
        case .moveToFolder: if let preset { sidebarMoveTarget = .preset(preset.id) } else { refuse(noPreset) }
        case .moveUp, .moveDown:
            guard let preset else { refuse(noPreset); return }
            // The favorites list is sorted by name, so a move there would
            // reorder a folder that is not on screen.
            guard !(presetStore.showFavoritesOnly && !presetStore.favoritePresets.isEmpty) else {
                refuse(String(localized: "Turn off Favorites only to reorder presets")); return
            }
            // Search results mix folders the same way.
            guard !isSearching else {
                refuse(String(localized: "Clear the search to reorder presets")); return
            }
            let list = presetStore.presets(in: preset.groupID)
            guard let i = list.firstIndex(where: { $0.id == preset.id }) else { return }
            let up = command == .moveUp
            guard up ? i > 0 : i < list.count - 1 else {
                refuse(up ? String(localized: "Already first") : String(localized: "Already last")); return
            }
            presetStore.movePresets(in: preset.groupID, fromOffsets: IndexSet(integer: i), toOffset: up ? i - 1 : i + 2)
            AccessibilityNotification.Announcement(String(localized: "Moved to position \(up ? i : i + 2)")).post()
        case .renameFolder:
            if let folder { renameGroupName = ShippedText.t(folder.name); renamingGroup = folder } else { refuse(noFolder) }
        case .folderColor:
            if let folder {
                // Half a second later: another sheet may have gone up since.
                revealFolder(folder) { guard canPresentSheet else { return }; colorEditingGroup = folder }
            } else { refuse(noFolder) }
        case .newSubfolder:
            guard let folder else { refuse(noFolder); return }
            let id = presetStore.createGroup(named: String(localized: "New Folder").withoutRTLMark, parentID: folder.id)
            presetStore.setGroupExpanded(folder.id, true)
            if let g = presetStore.groups.first(where: { $0.id == id }) { renameGroupName = g.name; renamingGroup = g }
        case .deleteFolder:
            if let folder {
                revealFolder(folder) { guard canPresentSheet else { return }; folderPendingDelete = folder.id }
            } else { refuse(noFolder) }
        case .moveFolderInto: if let folder { sidebarMoveTarget = .folder(folder.id) } else { refuse(noFolder) }
        case .folderUp, .folderDown:
            guard let folder else { refuse(noFolder); return }
            guard folder.parentID == nil else { refuse(String(localized: "Only top-level folders move up and down")); return }
            let list = folder.isBuiltIn ? presetStore.builtInTopLevelGroups : presetStore.userTopLevelGroups
            guard let i = list.firstIndex(where: { $0.id == folder.id }) else { return }
            let up = command == .folderUp
            guard up ? i > 0 : i < list.count - 1 else {
                refuse(up ? String(localized: "Already first") : String(localized: "Already last")); return
            }
            presetStore.moveTopLevelGroups(builtIn: folder.isBuiltIn, fromOffsets: IndexSet(integer: i), toOffset: up ? i - 1 : i + 2)
            AccessibilityNotification.Announcement(String(localized: "Moved to position \(up ? i : i + 2)")).post()
        case .nextFolder, .previousFolder:
            // Every folder in path order, so an empty folder or a parent of
            // subfolders only can be picked without a pointer.
            let paths = groupPathChoices.filter { !(presetStore.hideBuiltInPresets && presetStore.isInBuiltInFolder($0.id)) }
            guard !paths.isEmpty else { refuse(String(localized: "No folders")); return }
            let at = folderID.flatMap { id in paths.firstIndex { $0.id == id } }
            let next = command == .nextFolder
                ? (at.map { ($0 + 1) % paths.count } ?? 0)
                : (at.map { ($0 - 1 + paths.count) % paths.count } ?? paths.count - 1)
            selectedFolderID = paths[next].id
            if let g = presetStore.groups.first(where: { $0.id == paths[next].id }) {
                revealFolder(g) {}
            }
            AccessibilityNotification.Announcement(String(localized: "Folder \(paths[next].path) selected")).post()
        case .toggleFolder:
            guard let folder else { refuse(noFolder); return }
            let opening = !folder.isExpanded
            presetStore.toggleGroupExpanded(folder.id)
            // Closing the folder the selected preset is in (or one of its
            // subfolders) leaves the folder selected, not a hidden row; set
            // after the selection change, which clears the folder.
            if !opening, let preset, let gid = preset.groupID, presetStore.isGroup(gid, descendantOfOrEqualTo: folder.id) {
                selectedPresetId = nil
                DispatchQueue.main.async { selectedFolderID = folder.id }
            }
            AccessibilityNotification.Announcement(opening ? String(localized: "Expanded") : String(localized: "Collapsed")).post()
        case .expandAll:
            for g in presetStore.groups where !g.isExpanded { presetStore.setGroupExpanded(g.id, true) }
            AccessibilityNotification.Announcement(String(localized: "All folders expanded")).post()
        case .collapseAll:
            for g in presetStore.groups where g.isExpanded { presetStore.setGroupExpanded(g.id, false) }
            // The target becomes the top-level folder it sits in, which is
            // still on screen.
            var top = folderID
            var hops = 0
            while let id = top, hops < 8, let parent = presetStore.groups.first(where: { $0.id == id })?.parentID { top = parent; hops += 1 }
            if preset?.groupID != nil { selectedPresetId = nil }
            DispatchQueue.main.async { selectedFolderID = top }
            AccessibilityNotification.Announcement(String(localized: "All folders collapsed")).post()
        case .showTrash:
            guard !presetStore.recentlyDeleted.isEmpty || !presetStore.deletedFolders.isEmpty else {
                refuse(String(localized: "The Trash is empty")); return
            }
            showingTrashDisclosure = true
            NotificationCenter.default.post(name: .inputConfigScrollToPreset, object: Self.trashSectionID)
            AccessibilityNotification.Announcement(String(localized: "Trash opened")).post()
        case .trashItems:
            guard !presetStore.recentlyDeleted.isEmpty || !presetStore.deletedFolders.isEmpty else {
                refuse(String(localized: "The Trash is empty")); return
            }
            showingTrashSheet = true
        case .restoreLastDeleted:
            // The newest thing in the Trash, preset or folder.
            let lastPreset = presetStore.recentlyDeleted.max { $0.deletedAt < $1.deletedAt }
            let lastFolder = presetStore.deletedFolders.first
            if let f = lastFolder, f.deletedAt > (lastPreset?.deletedAt ?? .distantPast) {
                presetStore.restoreDeletedFolder(f)
                AccessibilityNotification.Announcement(String(localized: "Put back")).post()
            } else if let p = lastPreset {
                if presetStore.restoreDeleted(p) {
                    revealPreset(p.preset.id)
                    AccessibilityNotification.Announcement(String(localized: "Put back \(p.preset.shownName)")).post()
                }
            } else {
                refuse(String(localized: "The Trash is empty"))
            }
        case .emptyTrash:
            guard !presetStore.recentlyDeleted.isEmpty || !presetStore.deletedFolders.isEmpty else {
                refuse(String(localized: "The Trash is empty")); return
            }
            // Opened and scrolled to first: the dialog hangs off the Trash's
            // own button, which a collapsed or scrolled-off Trash lacks.
            confirmingEmptyTrash = true
        }
    }

    static let trashSectionID = "sidebar-trash"

    /// The copy is selected and said, so it can be found.
    private func duplicateAndAnnounce(_ preset: Preset) {
        // With the name, tag and notes still being typed (P2's drafts).
        let copy = presetStore.duplicatePreset(committed(preset))
        revealPreset(copy.id)
        AccessibilityNotification.Announcement(String(localized: "Duplicated as \(copy.shownName)")).post()
    }

    /// Which way the star went, since the command name does not say.
    private func toggleFavoriteAndAnnounce(_ preset: Preset) {
        presetStore.toggleFavorite(preset)
        AccessibilityNotification.Announcement(presetStore.isFavorite(preset)
            ? String(localized: "Added to Favorites") : String(localized: "Removed from Favorites")).post()
    }

    /// Select a preset and make its row visible: Favorites only off when it
    /// is not a favorite, its folders open, scrolled to.
    func revealPreset(_ id: UUID) {
        guard let preset = presetStore.presets.first(where: { $0.id == id }) else { return }
        // A hidden folder has no row to scroll to: looking for one built
        // every sidebar row twice, and nothing said where the preset went.
        if presetStore.hideBuiltInPresets, presetStore.isInBuiltInFolder(preset.groupID) {
            selectedPresetId = id
            AccessibilityNotification.Announcement(String(localized: "This preset's folder is hidden by Hide built-in presets.")).post()
            return
        }
        if presetStore.showFavoritesOnly, !presetStore.isFavorite(preset) { presetStore.showFavoritesOnly = false }
        if isSearching, !sidebarSearchResults.contains(where: { $0.id == id }) { sidebarQuery = "" }
        var parent = preset.groupID
        var hops = 0
        while let gid = parent, hops < 8, let g = presetStore.groups.first(where: { $0.id == gid }) {
            if !g.isExpanded { presetStore.setGroupExpanded(gid, true) }
            parent = g.parentID
            hops += 1
        }
        selectedPresetId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .inputConfigScrollToPreset, object: id)
        }
    }

    /// Bring a folder's header into the list (Favorites only off, its
    /// parents open, scrolled to) before a popover or dialog that hangs off
    /// it, which otherwise never showed and popped up later unasked.
    private func revealFolder(_ folder: PresetGroup, then action: @escaping () -> Void) {
        var needsWait = false
        // Search results draw no folder headers.
        if isSearching { sidebarQuery = ""; needsWait = true }
        if presetStore.showFavoritesOnly && !presetStore.favoritePresets.isEmpty {
            presetStore.showFavoritesOnly = false
            needsWait = true
        }
        var parent = folder.parentID
        var hops = 0
        while let id = parent, hops < 8, let g = presetStore.groups.first(where: { $0.id == id }) {
            if !g.isExpanded { presetStore.setGroupExpanded(id, true); needsWait = true }
            parent = g.parentID
            hops += 1
        }
        NotificationCenter.default.post(name: .inputConfigScrollToPreset, object: folder.id)
        // Again once the rebuilt or expanded rows exist; the first request
        // ran against the list as it was.
        DispatchQueue.main.asyncAfter(deadline: .now() + (needsWait ? 0.5 : 0.3)) {
            NotificationCenter.default.post(name: .inputConfigScrollToPreset, object: folder.id)
            action()
        }
    }

    /// Folders this folder may be moved into: every folder except itself and
    /// its own descendants (moving into those would create a cycle).
    /// Every folder with its ancestors in the name ("Gaming / First-Person"),
    /// sorted by that path, for the preset row's Move to Group menu.
    /// Built once per change of the folders or of Hide Built-in (see
    /// GroupPathMemo), not once per row per render as the computed list was.
    private var groupPathChoices: [(id: UUID, path: String)] {
        groupPathMemo.paths(groups: presetStore.groups, hideBuiltIn: presetStore.hideBuiltInPresets,
                            computeGroupPathChoices)
    }

    private func computeGroupPathChoices() -> [(id: UUID, path: String)] {
        let byID = Dictionary(uniqueKeysWithValues: presetStore.groups.map { ($0.id, $0) })
        func path(_ g: PresetGroup) -> String {
            var parts = [ShippedText.t(g.name)]
            var cursor = g.parentID
            var hops = 0
            while let pid = cursor, let parent = byID[pid], hops < 8 {
                parts.insert(ShippedText.t(parent.name), at: 0)
                cursor = parent.parentID
                hops += 1
            }
            return parts.joined(separator: " / ")
        }
        // A hidden built-in folder is no place to move to: what went there
        // vanished from the sidebar and from search.
        return presetStore.groups
            .filter { !(presetStore.hideBuiltInPresets && presetStore.isInBuiltInFolder($0.id)) }
            .map { ($0.id, path($0)) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    /// Where the Move to Folder sheet can put its target, as paths.
    private func moveChoices(for target: SidebarMoveTarget) -> [(id: UUID, path: String)] {
        switch target {
        case .preset: return groupPathChoices
        case .folder(let id):
            guard let group = presetStore.groups.first(where: { $0.id == id }) else { return [] }
            let allowed = Set(eligibleParentFolders(for: group).map(\.id))
            return groupPathChoices.filter { allowed.contains($0.id) }
        }
    }

    private func eligibleParentFolders(for group: PresetGroup) -> [PresetGroup] {
        presetStore.groups
            .filter { !presetStore.isGroup($0.id, descendantOfOrEqualTo: group.id) }
            .filter { !(presetStore.hideBuiltInPresets && presetStore.isInBuiltInFolder($0.id)) }
            .sorted { ShippedText.t($0.name).localizedStandardCompare(ShippedText.t($1.name)) == .orderedAscending }
    }

    /// Map a `PresetGroup.color` value to a SwiftUI Color, or nil for no
    /// tint. Accepts both a named palette color and a "#RRGGBB" hex string
    /// (chosen via the macOS color picker). Kept in the view layer so the
    /// model stays AppKit / Color agnostic.
    /// The id of the last row a top-level folder currently shows, so that
    /// row can close the folder's outline. Children render as nested folders
    /// first, then presets, so the last preset wins; otherwise the last
    /// nested folder, descending into it while it is expanded; otherwise the
    /// folder's own header (empty or collapsed).
    func lastVisibleRowID(in group: PresetGroup) -> AnyHashable {
        guard group.isExpanded else { return AnyHashable(group.id) }
        let presets = presetStore.presets(in: group.id)
        if let last = presets.last { return AnyHashable(last.id) }
        let subs = presetStore.subgroups(of: group.id)
        if let lastSub = subs.last {
            return lastSub.isExpanded ? lastVisibleRowID(in: lastSub) : AnyHashable(lastSub.id)
        }
        return AnyHashable("empty-\(group.id.uuidString)")
    }

    func groupTintColor(for group: PresetGroup) -> Color? {
        guard let value = group.color else { return nil }
        if value.hasPrefix("#") { return Self.color(fromHex: value) }
        return namedColor(value)
    }

    /// Palette name -> Color (the fixed `PresetGroup.colorOptions` set).
    private func namedColor(_ name: String) -> Color? {
        switch name {
        case "blue":   return .blue
        case "purple": return .purple
        case "pink":   return .pink
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "teal":   return .teal
        case "indigo": return .indigo
        case "brown":  return .brown
        default:       return nil
        }
    }

    /// Parse "#RRGGBB" into an sRGB Color. nil on malformed input.
    static func color(fromHex hex: String) -> Color? {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255.0,
                     green: Double((v >> 8) & 0xFF) / 255.0,
                     blue: Double(v & 0xFF) / 255.0)
    }

    /// Serialize a Color to "#RRGGBB" (sRGB) for storage in PresetGroup.color.
    static func hexString(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = max(0, min(255, Int(round(ns.redComponent * 255))))
        let g = max(0, min(255, Int(round(ns.greenComponent * 255))))
        let b = max(0, min(255, Int(round(ns.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// The folder color popover's None and Restore Default buttons.
    @ViewBuilder
    private func folderColorButtons(for group: PresetGroup) -> some View {
        Button("None") {
            presetStore.setGroupColor(group.id, color: nil)
            colorEditingGroup = nil
        }
        .buttonStyle(.solidSecondaryCompact)
        .fixedSize()
        if ExamplePresets.groupDefaultColors[group.name] != nil {
            Button("Restore Default") {
                presetStore.applyDefaultGroupColor(group.id)
                colorEditingGroup = nil
            }
            .buttonStyle(.solidSecondaryCompact)
            .fixedSize()
        }
    }

    /// Folder-color editor popover: tinted palette swatches (so the colors
    /// are actually visible) plus a macOS ColorPicker for any custom color
    /// (stored as hex). Also offers None / Restore Default.
    @ViewBuilder
    private func folderColorPopover(for group: PresetGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder Color")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                ForEach(PresetGroup.colorOptions, id: \.self) { name in
                    Button {
                        presetStore.setGroupColor(group.id, color: name)
                        colorEditingGroup = nil
                    } label: {
                        Circle()
                            .fill(namedColor(name) ?? .gray)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(
                                    Color.primary.opacity(group.color == name ? 0.9 : 0.15),
                                    lineWidth: group.color == name ? 2 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(localizedColorName(name))
                    .accessibilityLabel(localizedColorName(name))
                    .accessibilityAddTraits(group.color == name ? [.isSelected] : [])
                }
            }

            Divider()

            // Any custom color via the native macOS color picker.
            HStack(spacing: 10) {
                ColorPicker("Custom folder color", selection: $folderPickerColor, supportsOpacity: false)
                    .labelsHidden()
                Text("Custom color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") {
                    presetStore.setGroupColor(group.id, color: Self.hexString(from: folderPickerColor))
                    colorEditingGroup = nil
                }
                .buttonStyle(.solidCompact)
            }

            Divider()

            // Side by side when they fit, stacked when a translation of
            // Restore Default is too long to share the row.
            ViewThatFits(in: .horizontal) {
                HStack { folderColorButtons(for: group); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 6) { folderColorButtons(for: group) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 250)
        .onAppear {
            folderPickerColor = groupTintColor(for: group) ?? .accentColor
        }
    }

    /// Sidebar row for one deleted preset. Restore moves it back to the
    /// presets directory; the trash icon permanently nukes the entry.
    @ViewBuilder
    /// A trashed folder: put back restores the folder, its subfolders, and
    /// every preset that was inside.
    private func trashFolderRow(entry: PresetStore.DeletedFolder) -> some View {
        let count = entry.presets.count
        let countText = count == 1 ? String(localized: "1 preset") : String(localized: "\(count) presets")
        return HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption2)
                .foregroundStyle(.hint)
            VStack(alignment: .leading, spacing: 1) {
                Text(ShippedText.t(entry.name))
                    .font(.caption)
                    .lineLimit(1)
                Text("\(countText), \(trashDateString(entry.deletedAt))")
                    .font(.caption2)
                    .foregroundStyle(.hint)
            }
            Spacer(minLength: 4)
            Button {
                presetStore.restoreDeletedFolder(entry)
                AccessibilityNotification.Announcement(String(localized: "Put back \(ShippedText.t(entry.name))")).post()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .frame(width: 22 * max(1, editorTextScale), height: 22 * max(1, editorTextScale))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Put back the folder and everything in it")
            .accessibilityLabel(String(localized: "Put back \(ShippedText.t(entry.name))"))
            .voiceNames("Put back folder")
            Button {
                pendingFolderDelete = entry.id
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 22 * max(1, editorTextScale), height: 22 * max(1, editorTextScale))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete the folder and its presets permanently")
            .accessibilityLabel(String(localized: "Delete \(ShippedText.t(entry.name)) permanently"))
            .voiceNames("Delete folder permanently")
            .confirmationDialog("Delete the folder \u{201C}\(ShippedText.t(entry.name))\u{201D} and its presets permanently?",
                                isPresented: Binding(get: { pendingFolderDelete == entry.id },
                                                     set: { if !$0 { pendingFolderDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Permanently", role: .destructive) {
                    presetStore.permanentlyDeleteFolder(entry)
                    AccessibilityNotification.Announcement(String(localized: "\(ShippedText.t(entry.name)) deleted permanently")).post()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It cannot be put back.")
            }
        }
        .padding(.vertical, 3)
    }

    private func trashRow(entry: PresetStore.DeletedPreset) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption2)
                .foregroundStyle(.hint)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.preset.shownName)
                    .font(.caption)
                    .lineLimit(1)
                Text(trashDateString(entry.deletedAt))
                    .font(.caption2)
                    .foregroundStyle(.hint)
            }
            Spacer(minLength: 4)
            Button {
                _ = presetStore.restoreDeleted(entry)
                revealPreset(entry.preset.id)
                AccessibilityNotification.Announcement(String(localized: "Put back \(entry.preset.shownName)")).post()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .frame(width: 22 * max(1, editorTextScale), height: 22 * max(1, editorTextScale))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Put back")
            .accessibilityLabel(String(localized: "Put back \(entry.preset.shownName)"))
            .voiceNames("Put back preset")
            Button {
                pendingPresetDelete = entry.id
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 22 * max(1, editorTextScale), height: 22 * max(1, editorTextScale))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete permanently")
            .accessibilityLabel(String(localized: "Delete \(entry.preset.shownName) permanently"))
            .voiceNames("Delete preset permanently")
            .confirmationDialog("Delete \u{201C}\(entry.preset.shownName)\u{201D} permanently?",
                                isPresented: Binding(get: { pendingPresetDelete == entry.id },
                                                     set: { if !$0 { pendingPresetDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Permanently", role: .destructive) {
                    presetStore.permanentlyDelete(entry)
                    AccessibilityNotification.Announcement(String(localized: "\(entry.preset.shownName) deleted permanently")).post()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It cannot be put back.")
            }
        }
        .padding(.vertical, 3)
    }

    /// One formatter for every Trash row, not one per row per render.
    @MainActor private static let trashDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func trashDateString(_ date: Date) -> String {
        String(localized: "Deleted \(Self.trashDateFormatter.localizedString(for: date, relativeTo: Date()))")
    }

    /// Made inside SidebarRows, so it reads the selection only through the
    /// row's own PresetRowSelection (see `sidebarRowsContent`).
    @ViewBuilder
    private func presetRow(for preset: Preset, leadingInset: CGFloat = -18,
                           outline: (FolderOutlineRole, Color)? = nil) -> some View {
        let rowSelection = selection.row(for: preset.id)
        PresetRowView(
            preset: preset,
            onActivate: { togglePreset(committed(preset)) },
            onEdit: { editingPreset = committed(preset) },
            onDuplicate: { duplicateAndAnnounce(preset) },
            onExport: { exportPreset(preset) },
            onShowInFinder: { showPresetInFinder(preset) },
            onShare: { sharePreset(preset) },
            onImport: { showingImportSheet = true },
            onDelete: { confirmDelete(preset) },
            onConvert: { source, dest in
                // Shown and said, as Duplicate does: under Favorites only the
                // new copy was hidden and nothing changed on screen.
                let copy = presetStore.convertPreset(preset, from: source, to: dest)
                revealPreset(copy.id)
                AccessibilityNotification.Announcement(String(localized: "Converted to \(copy.shownName)")).post()
            },
            groupChoices: groupPathChoices,
            currentGroupID: preset.groupID,
            onMoveToGroup: { target in
                presetStore.setPresetGroup(preset.id, groupID: target)
                // Its new folder and the ones above it open, so it shows.
                if target != nil { revealPreset(preset.id) }
            },
            onNewGroup: {
                creatingGroupForPreset = preset
                newGroupName = String(localized: "New Group").withoutRTLMark
                pendingGroupPresetIDs = [preset.id]
            },
            isFavorite: presetStore.isFavorite(preset),
            onToggleFavorite: { toggleFavoriteAndAnnounce(preset) },
            selection: rowSelection,
            onMove: { up in
                selectedPresetId = preset.id
                handleSidebarCommand(up ? .moveUp : .moveDown)
            }
        )
        // The folder's last row is taller by its gap to the outline, so its
        // selection clears the line with the same 8 points as at the sides.
        // Padding on the row itself: macOS 27's List dropped a larger bottom
        // row inset, and the selection, drawn for the taller row, ended
        // across the description.
        .padding(.bottom, outline.map { $0.0.closesFolder } == true ? 10 : 0)
        .background(SidebarRowAnchor(id: preset.id))
        // A click on a preset moves the highlight off a folder header, even
        // on the preset that was already selected. It selects the row itself
        // too: on macOS 15 a row click did not always reach the List's own
        // selection, which left the page on Welcome (GitHub issue 15).
        .background(SidebarClickTarget {
            selectedPresetIdBinding.wrappedValue = preset.id
            selectedFolderID = nil
        })
        .tag(preset.id)
        .id(preset.id) // For ScrollViewReader.scrollTo
        // List(.sidebar) default row insets give the row a fat
        // leading gutter (~16pt) which pushes the active-indicator
        // dot well away from the left edge. The DisclosureGroup
        // wrapping the group additionally indents children by the
        // disclosure-triangle width. Push hard with a generous
        // negative leading inset so the active dot sits flush with
        // the group disclosure column; the trailing inset keeps the
        // ellipsis inside the folder outline, 20 points from the
        // scroll bar.
        .listRowInsets(EdgeInsets(top: 2, leading: leadingInset, bottom: 2, trailing: 18))
        .listRowBackground(
            PresetRowBackground(selection: rowSelection,
                                flashing: flashingPresetID == preset.id,
                                isActive: preset.isActive,
                                outlineRole: outline?.0, outlineColor: outline?.1)
        )
        .draggable(preset.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // Drop one preset onto another → put it at that row's position.
            // Reorders inside a folder and moves between folders with the same
            // gesture. This used to create a new folder from the two presets,
            // which meant there was no way to reorder at all; that action is
            // still on the row's context menu as "New Group…".
            // Not in the Favorites list: it is sorted by name, so a drop there
            // changed nothing in view and quietly moved the preset into the
            // other one's folder.
            if presetStore.showFavoritesOnly && !presetStore.favoritePresets.isEmpty { return false }
            // Nor in search results, which mix folders the same way.
            if !sidebarQuery.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            var handled = false
            for item in items {
                if let uuid = UUID(uuidString: item), uuid != preset.id {
                    presetStore.movePreset(uuid, toPositionOf: preset.id)
                    handled = true
                }
            }
            return handled
        }
    }



    @ViewBuilder
    private func newGroupSheet(for preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group")
                .font(.headline)
            Text("Create a group to organize related presets together in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Group name", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .focused($groupNameFocused)
                .onAppear { DispatchQueue.main.async { groupNameFocused = true } }
            HStack {
                Spacer()
                Button("Cancel") {
                    creatingGroupForPreset = nil
                    pendingGroupPresetIDs = []
                }
                .buttonStyle(.solidSecondary)
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = (name.isEmpty ? String(localized: "New Group") : name).withoutRTLMark
                    let newID = presetStore.createGroup(named: resolved,
                                                        includingPresets: pendingGroupPresetIDs)
                    creatingGroupForPreset = nil
                    pendingGroupPresetIDs = []
                    // The new folder is the folder commands' target, so an
                    // empty one can be renamed or colored from the keyboard.
                    selectedFolderID = newID
                    // Brief green flash on the new group in the sidebar.
                    flashingGroupID = newID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                        if flashingGroupID == newID { flashingGroupID = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private func renameGroupSheet(for group: PresetGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Group")
                .font(.headline)
            TextField("Group name", text: $renameGroupName)
                .textFieldStyle(.roundedBorder)
                .focused($groupNameFocused)
            HStack {
                Spacer()
                Button("Cancel") {
                    renamingGroup = nil
                }
                .buttonStyle(.solidSecondary)
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Saved unchanged, a built-in folder keeps its English
                    // name, which reseeding and backups find it by.
                    if !name.isEmpty, name != ShippedText.t(group.name) {
                        presetStore.renameGroup(group.id, to: name)
                    }
                    renamingGroup = nil
                }
                .buttonStyle(.solid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            // Async so the sheet's field is in the window before focusing.
            DispatchQueue.main.async { groupNameFocused = true }
        }
    }

    private func groupExpandedBinding(for group: PresetGroup) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding(
            get: { group.isExpanded },
            set: { presetStore.setGroupExpanded(group.id, $0) }
        )
    }

    static let controllerColors: [Color] = [.green, .purple, .red, .orange, .cyan, .pink, .yellow, .mint]

    /// An 8BitDo controller is considered to be in the wrong mode if HID
    /// detection sees it but the GameController framework does not have a
    /// corresponding entry (or has fewer entries than the HID detector).
    var eightBitDoModeWarning: EightBitDoDevice? {
        let hidDevices = eightBitDoDetector.detectedDevices
        guard !hidDevices.isEmpty else { return nil }
        // If at least one detected 8BitDo device is in a non-supported mode,
        // surface it. Apple mode controllers are also picked up by GCController,
        // so we only warn for the others.
        // The first one InputConfig is not already reading directly: a
        // pad read through raw HID needs no hint, and checking only the
        // first unsupported pad hid the hint for a second one.
        return hidDevices.first { device in
            !device.mode.supportedByMacOS && !controllerService.rawHIDGamepadSlots.values.contains {
                $0.vendorID == EightBitDoDetector.vendorID && $0.productID == device.productID
            }
        }
    }
}

/// A preset row's background: its piece of the folder outline, then the
/// selection, the running tint or the flash. Its own view so a switch redraws
/// it from the row's PresetRowSelection alone, without the rows being made
/// again (SidebarRows).
struct PresetRowBackground: View {
    let selection: PresetRowSelection
    let flashing: Bool
    let isActive: Bool
    var outlineRole: FolderOutlineRole?
    var outlineColor: Color?

    var body: some View {
        let selected = selection.isSelected
        ZStack {
            // The enclosing folder's outline piece, if this row is in one.
            if let outlineRole, let outlineColor {
                FolderOutlineSegment(role: outlineRole, color: outlineColor)
            }
            // Brief flash when the user jumps here from a feature demo;
            // otherwise a steady green hint marks the actively running
            // preset. Matches the system selection pill exactly: same
            // continuous-corner curvature and the same inset, so the green
            // hint sits in the identical box the blue selection draws.
            // The selection is drawn here, not by the list: the list's
            // own spans the whole row, past the folder outline's right
            // edge, which sits 20 points from the scroll bar.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // The flash first: the row that flashes was just selected.
                .fill(flashing
                      ? Color.green.opacity(selected ? 0.75 : 0.35)
                      : selected ? Color.accentColor
                      : (isActive ? Color.green.opacity(0.16) : Color.clear))
                .padding(.leading, 8)
                .padding(.trailing, 28.5)
                .padding(.top, 1)
                .padding(.bottom, outlineRole?.closesFolder == true ? 11 : 1)
            // Deliberately NO implicit .animation here: List reuses row
            // views while scrolling, and an animation keyed on isActive /
            // flashingPresetID replayed the green fade on whichever preset
            // was recycled into the old active row's slot (a green flash
            // ~2/3 down the list while scrolling). The flash fade-out is
            // driven explicitly with withAnimation where the flash clears.
        }
    }
}
