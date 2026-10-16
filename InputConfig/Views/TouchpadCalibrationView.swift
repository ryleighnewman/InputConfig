import SwiftUI

/// The touchpad's regions: areas of a DualSense or DualShock 4 touchpad,
/// each its own input that fires while a finger is inside it. Drawn in the
/// editor's Regions section, or in this sheet from the app menu with no
/// preset open. The per-region "Bind to" popover writes a binding straight
/// into the preset, so a region can be wired to a key without leaving.
/// The touchpad needs no calibration: macOS reports the whole pad.
struct TouchpadCalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var presetStore: PresetStore
    @Environment(\.appTextScale) private var textScale
    /// Not observed: its 60 Hz pointer publish re-rendered this whole sheet.
    private var cursorRegions: CursorRegionService { .shared }

    /// Which physical surface the sheet is operating on. Persisted in
    /// TouchpadService.currentActiveDevice so the picker reopens to the
    /// user's last pick.
    /// The Mac's own trackpad is not offered here any more (its areas are
    /// screen regions with their own editor), so a pick saved by an older
    /// version opens on the controller pad instead of a hidden choice.
    @State private var activeDevice: TouchpadDevice = {
        let saved = TouchpadService.shared.currentActiveDevice()
        return saved.usesCursorRegions ? .dualSense : saved
    }()
    /// Regions a finger is in, refreshed by the poll only when the set
    /// changes, so the highlights redraw on a press and not by chance.
    @State private var pressedRegionIDs: Set<UUID> = []

    // MARK: - Shared state

    /// Live finger 0 / 1 position in normalized 0..1 coordinates, refreshed
    /// at 30 Hz by the polling timer.
    @State private var liveFinger0: CGPoint?
    @State private var liveFinger1: CGPoint?
    @State private var pollTimer: Timer?

    private let surfaceWidth: Int
    private let surfaceHeight: Int

    // MARK: - Regions tab state

    /// Local copy of whichever region list the active device uses.
    /// Mutated by the UI, then pushed to TouchpadService or
    /// CursorRegionService depending on `activeDevice`.
    @State private var regions: [TouchpadRegion] = []
    @State private var selectedRegionID: UUID?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    #if DEBUG
    @State private var debugDraw: [Double]?
    @State private var debugCursor: [Double]?
    #endif
    @State private var drawingNewRegion = false
    /// What the drag under way does: draw, move or resize.
    @State private var dragMode: RectRegionDrag?
    @State private var renamingRegionID: UUID?
    /// The region whose Delete waits for its confirmation.
    @State private var pendingDeleteRegionID: UUID?
    @State private var confirmingApplyDefault = false
    @State private var confirmingReset = false
    @FocusState private var renameFocused: Bool
    @State private var renamingText: String = ""
    /// The region currently showing a "Bind to" popover. nil when no
    /// popover is open. Drives a popover anchored on the bind button in
    /// the region row.
    @State private var bindingPopoverRegionID: UUID?
    /// Confirmation toast after the "Apply default 1 to 16" action.
    @State private var showAppliedDefaultsToast: Bool = false

    /// Drawn inside the editor's Regions section: no title or Close.
    let embedded: Bool
    /// The pad: nil the main touchpad (a PlayStation pad's, or a Steam
    /// Controller's right trackpad), 1 a Steam Controller's left trackpad.
    let surface: Int?
    /// A Steam Controller's square trackpad rather than a PlayStation pad.
    let steam: Bool

    /// Where this pad's fingers and pressed regions are read.
    private var padService: TouchpadService { TouchpadService.forSurface(surface, steam: steam) }

    init(embedded: Bool = false, surface: Int? = nil, steam: Bool = false) {
        self.embedded = embedded
        self.surface = surface
        self.steam = steam
        let (w, h) = TouchpadService.shared.nominalSurfaceSize
        self.surfaceWidth = w
        self.surfaceHeight = h
    }

    var body: some View {
        Group {
        if embedded {
            embeddedBody
                .onReceive(NotificationCenter.default.publisher(for: .inputConfigTourSelectRegion)) { note in
                    let i = note.object as? Int ?? 0
                    selectedRegionID = regions.indices.contains(i) ? regions[i].id : nil
                }
                #if DEBUG
                .modifier(MarketingRegionHooks(draw: $debugDraw, cursor: $debugCursor) { i in
                    selectedRegionID = regions.indices.contains(i) ? regions[i].id : nil
                })
                #endif
        } else {
        VStack(alignment: .leading, spacing: 14) {
            Text("Touchpad Regions")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            regionsTab

            HStack {
                Spacer()
                // Escape backs out of a rename before it closes the sheet.
                // A click closes; Escape backs out of a rename or a drawing first.
                Button("Close") { dismiss() }
                    .buttonStyle(.solidSecondary)
                    .closesOnEscape {
                        if renamingRegionID != nil { renamingRegionID = nil }
                        else if drawingNewRegion { drawingNewRegion = false; dragStart = nil; dragCurrent = nil }
                        else { dismiss() }
                    }
                    .accessibilityLabel("Close touchpad setup")
                    .accessibilityInputLabels([Text("Close"), Text("Close touchpad setup")])
            }
        }
        .padding(22)
        .fixedSize()
        }
        }
        .onAppear {
            MappingEngine.touchpadSetupOpen = true
            TouchpadService.shared.retain()
            startPolling()
            reloadRegionsForActiveDevice()
        }
        // Undo and Redo in the editor put regions back into the service:
        // show them, unless a drag here is under way.
        .onReceive(NotificationCenter.default.publisher(for: TouchpadService.regionsDidChange)) { _ in
            if dragMode == nil, !drawingNewRegion { reloadRegionsForActiveDevice() }
        }
        .onDisappear {
            MappingEngine.touchpadSetupOpen = false
            stopPolling()
            TouchpadService.shared.release()
            saveRegionsOutsideEditor()
        }
    }

    /// In the editor's Regions section: one line saying what to do, then
    /// the touchpad and its regions.
    /// Laid out as the Adjust live sheet and the stick's Regions are: the
    /// hint, the touchpad, the buttons under it, then the list and what a
    /// finger is touching now.
    private var embeddedBody: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 10) {
                regionsPanel
                    .frame(width: padWidth, height: padWidth / regionsAspect)
                regionsToolbar
            }
            .frame(width: padWidth)
            VStack(alignment: .leading, spacing: 12) {
                Text(RegionEditorHint.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                regionsList
                VStack(alignment: .leading, spacing: 2) {
                    Text("In region")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(touchedNames.isEmpty ? String(localized: "None") : touchedNames.formatted(.list(type: .and)))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            .frame(width: 320 * min(1.6, max(1, textScale)), alignment: .leading)
        }
    }

    private var touchedNames: [String] { regions.filter { isRegionPressed($0.id) }.map(\.shownName) }

    /// The pad's width in the editor: a square Steam trackpad narrower than
    /// the wide PlayStation pad, so both stand about as tall as the stick.
    private var padWidth: CGFloat { (steam ? 260 : 380) * min(1.6, max(1, textScale)) }

    // MARK: - Regions tab

    @ViewBuilder
    private var regionsTab: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                if !embedded {
                    Text(regionsHeadline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if embedded {
                    regionsPanel
                        .frame(width: 440, height: 440 / regionsAspect)
                } else {
                    regionsPanel
                        .aspectRatio(regionsAspect, contentMode: .fit)
                }

                regionsToolbar
            }
            .frame(maxWidth: embedded ? 440 : .infinity, alignment: .leading)

            regionsList
                .frame(width: 260)
        }
    }

    private var regionsHeadline: String {
        if drawingNewRegion {
            return activeDevice == .macTrackpad
                ? String(localized: "Click and drag on the screen preview to draw the new cursor region.")
                : String(localized: "Click and drag on the touchpad surface to draw the new region.")
        }
        switch activeDevice {
        case .macTrackpad:
            return String(localized: "Cursor regions on the Mac Trackpad. Draw rectangles on the screen preview, then bind each one to a key or button.")
        case .dualSense, .dualShock4:
            return String(localized: "Regions on the controller's touchpad. A Touchpad region input fires while a finger is inside one.")
        }
    }

    private var regionsAspect: CGFloat {
        if activeDevice == .macTrackpad {
            if let frame = NSScreen.main?.frame, frame.height > 0 {
                return frame.width / frame.height
            }
            return 16.0 / 10.0
        }
        // A Steam Controller's trackpads are round-ish squares.
        if steam { return 1 }
        return CGFloat(surfaceWidth) / CGFloat(surfaceHeight)
    }

    @ViewBuilder
    private var regionsToolbar: some View {
        HStack(spacing: 8) {
            if embedded {
                regionCount
                Spacer(minLength: 0)
            }
            Button {
                addRegion(minX: 0.35, maxX: 0.65, minY: 0.35, maxY: 0.65)
            } label: {
                Label("Add Region", systemImage: "plus")
            }
            .buttonStyle(.solidSecondaryCompact)
            // Regions belong to a preset; with none open or running there
            // is nowhere to keep them, and they were dropped on close.
            .disabled(regions.count >= 16 || !hasTargetPreset)
            .help(hasTargetPreset ? String(localized: "Adds a region in the middle; or drag on the drawing to draw one") : String(localized: "Open or run a preset to add regions"))
            Button {
                // Asked first when it would replace regions someone placed.
                if regions.isEmpty { applyDefault1to16() } else { confirmingApplyDefault = true }
            } label: {
                Label("Apply default 1 to 16", systemImage: "square.grid.4x3.fill")
            }
            .confirmationDialog("Replace your regions with the 4 by 4 grid?",
                                isPresented: $confirmingApplyDefault, titleVisibility: .visible) {
                Button("Replace", role: .destructive) { applyDefault1to16() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The rows bound to your regions are replaced too.")
            }
            .buttonStyle(.solidSecondaryCompact)
            .help("Replace regions with a 4 by 4 grid and bind each to keys 1 to 9, 0, F1 to F6 in the preset being edited")
            .disabled(!hasTargetPreset)
            if !embedded {
                Spacer()
                regionCount
            }
        }
    }

    @ViewBuilder
    private var regionCount: some View {
            // The toast takes the count's place for its moment, so the row
            // never holds both.
            if showAppliedDefaultsToast {
                Label("Default grid applied", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else {
                Text("\(regions.count) / 16 regions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    private func previewPoints(_ size: CGSize) -> (CGPoint, CGPoint)? {
        #if DEBUG
        if let v = debugDraw {
            return (CGPoint(x: v[0] * size.width, y: v[1] * size.height), CGPoint(x: v[2] * size.width, y: v[3] * size.height))
        }
        #endif
        if drawingNewRegion, let start = dragStart, let current = dragCurrent { return (start, current) }
        return nil
    }

    /// A picture of the surface: left is left in every language.
    private var regionsPanel: some View { regionsPanelDrawing.environment(\.layoutDirection, .leftToRight) }

    private var regionsPanelDrawing: some View {
        GeometryReader { geo in
            ZStack {
                // The surface as the Adjust live sheet draws a trigger's bar.
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)

                ForEach(regions) { region in
                    regionShape(region: region, in: geo.size)
                }

                if let (start, current) = previewPoints(geo.size) {
                    let r = CGRect(
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y))
                    Rectangle()
                        .fill(Color.yellow.opacity(0.25))
                        .overlay(Rectangle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }

                if let id = selectedRegionID, let r = regions.first(where: { $0.id == id }) {
                    RegionCornerHandles(rect: CGRect(x: r.minX * geo.size.width, y: r.minY * geo.size.height,
                                                     width: (r.maxX - r.minX) * geo.size.width,
                                                     height: (r.maxY - r.minY) * geo.size.height),
                                        color: paletteColor(at: r.colorIndex))
                }

                fingerDots(in: geo.size)
                // Where the tour's pointer lands before it selects the first region.
                if let r = regions.first {
                    Color.clear
                        .frame(width: 24, height: 24)
                        .spotlightAnchor(SpotlightID.tourRegion)
                        .position(x: (r.minX + r.maxX) / 2 * geo.size.width, y: (r.minY + r.maxY) / 2 * geo.size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                #if DEBUG
                if let p = debugCursor { MarketingPointer(at: CGPoint(x: p[0] * geo.size.width, y: p[1] * geo.size.height)) }
                #endif
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(size: geo.size), including: .gesture)
        }
    }

    @ViewBuilder
    private func regionShape(region: TouchpadRegion, in size: CGSize) -> some View {
        let isPressed = pressedRegionIDs.contains(region.id)
        let isSelected = region.id == selectedRegionID
        let rect = CGRect(
            x: region.minX * size.width,
            y: region.minY * size.height,
            width: (region.maxX - region.minX) * size.width,
            height: (region.maxY - region.minY) * size.height)
        let color = paletteColor(at: region.colorIndex)
        // Lit and picked as the stick's and the trigger's regions are.
        let fillOpacity: Double = isPressed ? 0.32 : (isSelected ? 0.2 : 0.06)
        let strokeWidth: CGFloat = isPressed || isSelected ? 2.5 : 1

        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(fillOpacity))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(isPressed || isSelected ? 1 : 0.8), lineWidth: strokeWidth))
            .overlay(
                Text(region.shownName)
                    .font(.caption2)
                    .foregroundStyle(color.opacity(0.9))
                    .lineLimit(1)
                    .padding(4),
                alignment: .topLeading
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(region.shownName)
            .accessibilityValue(isPressed ? String(localized: "Active") : "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { if !drawingNewRegion { selectedRegionID = region.id } }
            .onTapGesture {
                if !drawingNewRegion {
                    selectedRegionID = region.id
                }
            }
            .contextMenu { regionMenuItems(region) }
    }

    /// The list, then typed bounds for the selected region: placing and
    /// sizing one took a pointer drag before, so keyboard, switch and
    /// VoiceOver users could only make a fixed box in the middle.
    private var regionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            regionsListBody
            if let id = selectedRegionID, let region = regions.first(where: { $0.id == id }) {
                // Written back by id, looked up when the field commits: the
                // field can commit as it goes away, after the region was
                // deleted or the list switched to another device, and an
                // index taken when this was drawn then hit the wrong region
                // or ran past the end.
                RegionBoundsFields(region: region) { updated in
                    guard let index = regions.firstIndex(where: { $0.id == updated.id }) else { return }
                    regions[index] = updated
                    persistRegions()
                }
                .id(region.id)
            }
        }
    }

    private var regionsListBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(embedded ? String(localized: "Regions")
                 : regionsOwnerName.map { String(localized: "Regions of \u{201C}\($0)\u{201D}") } ?? String(localized: "This preset's regions"))
                .font(embedded ? .subheadline : .caption.weight(.semibold))
                .foregroundStyle(embedded ? .primary : .secondary)
                .accessibilityAddTraits(.isHeader)
            if regions.isEmpty {
                Text(hasTargetPreset
                     ? String(localized: "None yet.")
                     : String(localized: "Regions belong to a preset. Open a preset in the editor, or run one, to add regions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !embedded { Spacer() }
            } else if embedded {
                // The editor scrolls; a list of its own would scroll inside it.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(regions) { region in
                        regionRow(region)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(regions) { region in
                            regionRow(region)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func regionRow(_ region: TouchpadRegion) -> some View {
        let isSelected = region.id == selectedRegionID
        let color = paletteColor(at: region.colorIndex)
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            if renamingRegionID == region.id {
                TextField("Name", text: $renamingText, onCommit: {
                    commitRename(for: region.id)
                })
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Rename region")
                .focused($renameFocused)
                .onExitCommand { renamingRegionID = nil }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(region.shownName)
                        .font(.body)
                        .lineLimit(1)
                    if let label = boundOutputLabel(for: region.id) {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Not bound")
                            .font(.caption2)
                            .foregroundStyle(.hint)
                    }
                }
                Spacer(minLength: 4)
            }
            if isRegionPressed(region.id) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            Button {
                bindingPopoverRegionID = region.id
            } label: {
                Image(systemName: "link")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!hasTargetPreset)
            .help(!hasTargetPreset
                  ? String(localized: "Open or create a preset to bind this region")
                  : String(localized: "Bind this region to a key"))
            .popover(isPresented: Binding(
                get: { bindingPopoverRegionID == region.id },
                set: { isShown in if !isShown { bindingPopoverRegionID = nil } }
            ), arrowEdge: .leading) {
                bindPopover(for: region)
            }
            .accessibilityLabel("Bind region \(region.shownName)")
            Menu {
                // Selecting shows the typed bounds, the way to place a
                // region without dragging; this menu is reachable by keyboard.
                Button("Select") { selectedRegionID = region.id }
                regionMenuItems(region)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Region options for \(region.shownName)")
            .help("Select, rename, duplicate or delete \(region.shownName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRegionID = region.id
        }
        // One named row, as in Screen Regions and Stick zones, saying
        // whether it is selected and whether a finger is in it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(region.shownName)
        .accessibilityValue([isSelected ? String(localized: "Selected") : nil, isRegionPressed(region.id) ? String(localized: "Active") : nil]
            .compactMap { $0 }.joined(separator: ", "))
        // Asked first: outside the editor a delete is saved at once, with
        // no undo, and the rows bound to the region stop firing.
        .confirmationDialog("Delete the region \u{201C}\(region.shownName)\u{201D}?",
                            isPresented: Binding(get: { pendingDeleteRegionID == region.id },
                                                 set: { if !$0 { pendingDeleteRegionID = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteRegion(region.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rows bound to it stop working.")
        }
    }

    // MARK: - Bind popover

    /// Compact key picker shown when the user taps the link icon next to
    /// a region. Selecting a key writes a binding into the active preset's
    /// first joystick slot and closes the popover.
    @ViewBuilder
    private func bindPopover(for region: TouchpadRegion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bind \(region.shownName) to…")
                .font(.subheadline.weight(.semibold))
            Text("Picks a key to fire while this region is active. The binding is added to the current preset.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(quickBindOptions, id: \.label) { option in
                        Button {
                            bindRegion(region.id, toKeyCode: option.keyCode, label: option.label)
                            bindingPopoverRegionID = nil
                        } label: {
                            HStack {
                                Text(option.label)
                                    .frame(minWidth: 38, alignment: .leading)
                                    .font(.body.monospaced())
                                Text(option.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 280, height: 240)
        }
        .padding(14)
    }

    private struct QuickBindOption {
        let label: String
        let description: String
        let keyCode: Int
    }

    /// The shortlist of common keys shown in the per-region bind popover.
    /// Number row + function row are the most useful for region work; the
    /// editor still has the full picker for anything more exotic.
    private var quickBindOptions: [QuickBindOption] {
        // Labels from the key itself: translated, and what the key types
        // under the keyboard layout, like every other key name in the app.
        func key(_ code: Int, _ description: String) -> QuickBindOption {
            QuickBindOption(label: KeyCodeMap.name(for: code), description: description, keyCode: code)
        }
        var opts: [QuickBindOption] = []
        for digit in 1...9 {
            opts.append(key(29 + digit, String(localized: "Number row")))
        }
        opts.append(key(39, String(localized: "Number row")))
        for fn in 1...12 {
            opts.append(key(57 + fn, String(localized: "Function row")))
        }
        opts.append(key(44, String(localized: "Spacebar")))
        opts.append(key(40, String(localized: "Enter / Return")))
        opts.append(key(43, String(localized: "Tab")))
        opts.append(key(41, String(localized: "Escape")))
        return opts
    }

    // MARK: - Region drawing

    /// A drag on a selected region's corner resizes it, inside a region
    /// moves it, and on empty pad draws a new one: no mode to enter first.
    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                let mode = dragMode ?? RectRegionDrag.mode(at: value.startLocation, size: size,
                                                          regions: regions, selected: selectedRegionID)
                dragMode = mode
                if mode != .draw {
                    if let changed = mode.apply(from: value.startLocation, to: value.location, size: size),
                       let i = regions.firstIndex(where: { $0.id == changed.id }) {
                        regions[i] = changed
                        selectedRegionID = changed.id
                    }
                    return
                }
                guard regions.count < 16, hasTargetPreset else { return }
                drawingNewRegion = true
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                defer { dragMode = nil }
                if let mode = dragMode, mode != .draw { persistRegions(); return }
                guard drawingNewRegion, let start = dragStart else { return }
                let end = value.location
                let normMinX = max(0, min(1, Double(min(start.x, end.x) / size.width)))
                let normMaxX = max(0, min(1, Double(max(start.x, end.x) / size.width)))
                let normMinY = max(0, min(1, Double(min(start.y, end.y) / size.height)))
                let normMaxY = max(0, min(1, Double(max(start.y, end.y) / size.height)))
                if (normMaxX - normMinX) > 0.04 && (normMaxY - normMinY) > 0.04 {
                    addRegion(minX: normMinX, maxX: normMaxX, minY: normMinY, maxY: normMaxY)
                }
                drawingNewRegion = false
                dragStart = nil
                dragCurrent = nil
            }
    }

    /// Rename, Duplicate and Delete: the region's right-click menu and the
    /// list row's menu.
    @ViewBuilder
    private func regionMenuItems(_ region: TouchpadRegion) -> some View {
        Button("Rename") {
            selectedRegionID = region.id
            renamingRegionID = region.id
            renamingText = region.shownName
            DispatchQueue.main.async { renameFocused = true }
        }
        Button("Duplicate") {
            guard regions.count < 16, hasTargetPreset else { return }
            let copy = RectRegionDrag.duplicate(region, name: String(localized: "Region \(regions.count + 1)").withoutRTLMark,
                                                colorIndex: regions.count % TouchpadRegion.colorPalette.count)
            regions.append(copy)
            selectedRegionID = copy.id
            persistRegions()
        }
        .disabled(regions.count >= 16 || !hasTargetPreset)
        Divider()
        Button("Delete\u{2026}", role: .destructive) {
            pendingDeleteRegionID = region.id
        }
    }

    private func addRegion(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let name = String(localized: "Region \(regions.count + 1)").withoutRTLMark
        let colorIndex = regions.count % TouchpadRegion.colorPalette.count
        var region = TouchpadRegion(name: name, minX: minX, maxX: maxX,
                                     minY: minY, maxY: maxY, colorIndex: colorIndex)
        region.surface = surface
        regions.append(region)
        selectedRegionID = region.id
        persistRegions()
    }

    private func deleteRegion(_ id: UUID) {
        regions.removeAll { $0.id == id }
        if selectedRegionID == id { selectedRegionID = nil }
        if activeDevice.usesCursorRegions {
            cursorRegions.deleteRegion(id)
        } else {
            saveTouchpadRegions()
        }
    }

    private func commitRename(for id: UUID) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unchanged, a built-in region keeps its English name on disk.
        if !trimmed.isEmpty, trimmed != regions[index].shownName {
            regions[index].name = trimmed
            persistRegions()
        }
        renamingRegionID = nil
        renamingText = ""
    }

    // MARK: - Shared bits

    /// Finger dot overlay driven by TimelineView, not by parent @State.
    ///
    /// The previous implementation read `liveFinger0` / `liveFinger1`
    /// @State written by the parent's 60 Hz pollOnce. Every finger
    /// move re-evaluated the *entire* TouchpadCalibrationView body
    /// (device picker, tab picker, helper text, stat blocks, buttons,
    /// the works) just to move one dot 8 pixels. The visualizer's
    /// TouchpadWidget doesn't have that problem because its trail uses
    /// a TimelineView whose updates don't go through parent @State.
    ///
    /// This subview adopts the same pattern: TimelineView ticks at
    /// 60 Hz from the display refresh, reads TouchpadService directly,
    /// and renders only the dots. The parent's @State is unaffected
    /// so the rest of the sheet stays static between ticks.
    @ViewBuilder
    private func fingerDots(in size: CGSize) -> some View {
        FingerDotsOverlay(size: size, service: padService)
    }



    private func paletteColor(at index: Int) -> Color {
        let safeIndex = max(0, min(TouchpadRegion.colorPalette.count - 1, index))
        switch TouchpadRegion.colorPalette[safeIndex] {
        case "mint":   return .mint
        case "cyan":   return .cyan
        case "pink":   return .pink
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "indigo": return .indigo
        case "green":  return .green
        default:       return .mint
        }
    }

    // MARK: - Device-aware region storage

    private func reloadRegionsForActiveDevice() {
        switch activeDevice {
        case .macTrackpad:
            regions = cursorRegions.allRegions()
        case .dualSense, .dualShock4:
            // This pad's own: the working set holds both Steam trackpads'.
            regions = TouchpadService.shared.allRegions().filter { ($0.surface == 1) == (surface == 1) }
        }
    }

    /// Push the current `regions` array to whichever service is the
    /// authoritative store for the active device.
    private func persistRegions() {
        switch activeDevice {
        case .macTrackpad:
            // CursorRegionService is upsert/delete style; rather than
            // diffing we replay the full list to keep it simple.
            // 1. Delete any region in the store that's no longer local.
            let localIDs = Set(regions.map { $0.id })
            for stored in cursorRegions.allRegions() where !localIDs.contains(stored.id) {
                cursorRegions.deleteRegion(stored.id)
            }
            // 2. Upsert the current locals (covers add + rename + resize).
            for region in regions {
                cursorRegions.upsert(region)
            }
        case .dualSense, .dualShock4:
            saveTouchpadRegions()
        }
    }

    /// This pad's regions back into the working set, beside the other pad's.
    private func saveTouchpadRegions() {
        let others = TouchpadService.shared.allRegions().filter { ($0.surface == 1) != (surface == 1) }
        TouchpadService.shared.saveRegions(others + regions)
    }

    /// Pressed-state lookup that routes to the right service.
    private func isRegionPressed(_ id: UUID) -> Bool {
        if activeDevice.usesCursorRegions {
            return cursorRegions.isRegionPressed(id)
        }
        return padService.isRegionPressed(id)
    }

    /// Look up the binding that currently fires this region in the active
    /// preset and produce a short label like "1" or "F2". nil if no
    /// matching binding exists yet.
    private func boundOutputLabel(for regionID: UUID) -> String? {
        guard let preset = targetPreset() else { return nil }
        let inputType: InputType = activeDevice.usesCursorRegions ? .cursorRegion : .touchpadRegion
        for joystick in preset.joysticks {
            for binding in joystick.bindings {
                guard binding.input.type == inputType else { continue }
                let bindingRegionID: UUID? = activeDevice.usesCursorRegions
                    ? binding.input.cursorRegionID
                    : binding.input.touchpadRegionID
                if bindingRegionID == regionID, !binding.outputs.isEmpty {
                    return outputLabel(for: binding)
                }
            }
        }
        return nil
    }

    /// The row's note when it has one ("Undo"), else every output by name
    /// ("Command (Left) + Z"). Only the first output was shown, by raw
    /// name, so every built-in zone read "Bound: Command (Left)".
    private func outputLabel(for binding: BindingModel) -> String? {
        if let note = binding.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return String(localized: "Bound: \(ShippedText.t(note))")
        }
        let outputNames = OutputAction.names(binding.outputs).joined(separator: " + ")
        return String(localized: "Bound: \(outputNames)")
    }

    // MARK: - Binding writes

    /// Add a `.touchpadRegion` (or `.cursorRegion`) binding for the given
    /// region to the target preset's first joystick. Replaces any
    /// existing binding pointing at the same region so the user always
    /// ends up with exactly one wire per region.
    private func bindRegion(_ regionID: UUID, toKeyCode keyCode: Int, label: String) {
        withTargetPreset { preset in
            guard !preset.joysticks.isEmpty else { return }

            let usesCursor = activeDevice.usesCursorRegions
            let inputType: InputType = usesCursor ? .cursorRegion : .touchpadRegion
            var newInput: InputEvent = usesCursor
                ? .cursorRegion(regionID)
                : .touchpadRegion(regionID)
            if !usesCursor { newInput.touchpadSurface = surface }
            let newOutput = OutputAction(type: .key, keyCode: keyCode)
            let newBinding = BindingModel(input: newInput, outputs: [newOutput])

            // Remove any prior binding pointing at this region so we don't
            // stack duplicate wires.
            for j in 0..<preset.joysticks.count {
                preset.joysticks[j].bindings.removeAll { b in
                    guard b.input.type == inputType else { return false }
                    let bID = usesCursor ? b.input.cursorRegionID : b.input.touchpadRegionID
                    return bID == regionID
                }
            }
            preset.joysticks[0].bindings.append(newBinding)
        }
    }

    /// Opened from the main window, the sheet edits the running
    /// preset's working set with no editor to save it, so the regions
    /// drawn here vanished at the next reload. Save them into the preset
    /// that owns the working set when anything changed.
    private func saveRegionsOutsideEditor() {
        guard OpenEditor.current == nil,
              let id = Preset.regionWorkingSetOwner,
              let idx = presetStore.presets.firstIndex(where: { $0.id == id }) else { return }
        var preset = presetStore.presets[idx]
        let before = preset
        preset.captureRegionsFromServices()
        guard preset.touchpadRegions != before.touchpadRegions
                || preset.cursorRegions != before.cursorRegions
                || preset.stickRegions != before.stickRegions else { return }
        presetStore.presets[idx] = preset
        presetStore.savePreset(preset)
    }

    /// The preset whose regions the sheet shows and saves into, by name,
    /// so it is never a guess which preset an edit lands in.
    private var regionsOwnerName: String? {
        targetPreset()?.shownName
    }

    /// The preset this sheet binds regions into: the open editor's draft
    /// when there is one, else the preset whose regions the sheet is
    /// showing, else the active preset. Binding always into the active
    /// preset wired regions into a preset other than the one being edited.
    private func targetPreset() -> Preset? {
        if let editor = OpenEditor.current { return editor.draft() }
        guard let id = Preset.regionWorkingSetOwner ?? presetStore.activePresetId else { return nil }
        return presetStore.presets.first { $0.id == id }
    }

    private var hasTargetPreset: Bool { targetPreset() != nil }

    /// Change the target preset. In the editor the change goes into the
    /// draft and is saved with it. Otherwise it is saved now, together
    /// with the regions its bindings point at: the services only hold the
    /// working set, and saving a binding without its region left a wire
    /// to a zone that did not exist after the next reload.
    private func withTargetPreset(_ change: (inout Preset) -> Void) {
        if let editor = OpenEditor.current {
            editor.edit(change)
            return
        }
        guard let id = Preset.regionWorkingSetOwner ?? presetStore.activePresetId,
              let idx = presetStore.presets.firstIndex(where: { $0.id == id }) else { return }
        var preset = presetStore.presets[idx]
        change(&preset)
        preset.captureRegionsFromServices()
        presetStore.presets[idx] = preset
        presetStore.savePreset(preset)
    }

    // MARK: - Default 1 to 16

    /// Replace the region list with a 4 by 4 grid and bind each cell to a
    /// number / function key in the active preset.
    private func applyDefault1to16() {
        guard let target = targetPreset(), !target.joysticks.isEmpty else { return }

        let usesCursor = activeDevice.usesCursorRegions
        let inputType: InputType = usesCursor ? .cursorRegion : .touchpadRegion


        // Generate a 4 by 4 grid (16 cells). Cell (col, row) maps to
        // normalized rectangle (col/4, row/4) to ((col+1)/4, (row+1)/4).
        let cellW = 1.0 / 4.0
        let cellH = 1.0 / 4.0
        let keyCodes: [Int] = (1...9).map { 29 + $0 } + [39] + (1...6).map { 57 + $0 }
        let keyLabels = (1...9).map { "\($0)" } + ["0"] + (1...6).map { "F\($0)" }

        var newRegions: [TouchpadRegion] = []
        var newBindings: [BindingModel] = []
        for cell in 0..<16 {
            let col = cell % 4
            let row = cell / 4
            var region = TouchpadRegion(
                name: keyLabels[cell],
                minX: Double(col) * cellW,
                maxX: Double(col + 1) * cellW,
                minY: Double(row) * cellH,
                maxY: Double(row + 1) * cellH,
                colorIndex: cell % TouchpadRegion.colorPalette.count
            )
            region.surface = surface
            newRegions.append(region)
            var input: InputEvent = usesCursor ? .cursorRegion(region.id) : .touchpadRegion(region.id)
            if !usesCursor { input.touchpadSurface = surface }
            let binding = BindingModel(
                input: input,
                outputs: [OutputAction(type: .key, keyCode: keyCodes[cell])]
            )
            newBindings.append(binding)
        }

        regions = newRegions
        persistRegions()
        // Sixteen bindings and their sixteen regions go to disk together.
        // Saving the bindings alone restarted the engine, which reloaded
        // the preset's old, empty region list over the grid just drawn.
        withTargetPreset { preset in
            // Wipe prior region bindings of the right type so we replace
            // cleanly rather than stacking.
            for j in 0..<preset.joysticks.count {
                // This pad's rows only: the other Steam trackpad keeps its own.
                preset.joysticks[j].bindings.removeAll {
                    $0.input.type == inputType && (usesCursor || ($0.input.touchpadSurface == 1) == (surface == 1))
                }
            }
            preset.joysticks[0].bindings.append(contentsOf: newBindings)
        }

        withAnimation(.easeIn(duration: 0.2)) { showAppliedDefaultsToast = true }
        AccessibilityNotification.Announcement(String(localized: "Default grid applied")).post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) { showAppliedDefaultsToast = false }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        // 60 Hz - matches typical display refresh and is the sweet spot
        // between smoothness and SwiftUI render cost. 120 Hz forced too
        // many @State invalidations per second and caused the sheet to
        // feel choppier than the underlying data was, because the
        // render pipeline couldn't keep up with the rate at which we
        // were dirtying the view.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            pollOnce()
        }
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Lights the regions a finger is in, redrawing only when that changes.
    private func pollOnce() {
        let pressed = Set(regions.map(\.id).filter { isRegionPressed($0) })
        if pressed != pressedRegionIDs { pressedRegionIDs = pressed }
    }
}

/// Self-refreshing finger position overlay. Reads `TouchpadService`
/// directly from inside a `TimelineView`, so updates don't have to
/// propagate through the parent `TouchpadCalibrationView`'s @State and
/// re-evaluate its whole body. This is the same architectural pattern
/// the live visualizer's `TouchpadWidget` uses for its trail canvas.
///
/// The dots stay in sync with finger motion at 60 Hz without forcing
/// the much heavier surrounding sheet body (device picker, tab picker,
/// banner, stat blocks, save / quick-zero / reset buttons) to redraw.
private struct FingerDotsOverlay: View {
    let size: CGSize
    /// The pad whose fingers are drawn.
    var service: TouchpadService = .shared

    /// Cached touchpad surface dimensions. Same value the parent reads
    /// via TouchpadService.nominalSurfaceSize; pulling it once at init
    /// instead of inside the timeline closure keeps the hot path
    /// allocation-free.
    private let surfaceWidth: CGFloat
    private let surfaceHeight: CGFloat

    init(size: CGSize, service: TouchpadService = .shared) {
        self.size = size
        self.service = service
        let (w, h) = TouchpadService.shared.nominalSurfaceSize
        self.surfaceWidth = CGFloat(w)
        self.surfaceHeight = CGFloat(h)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { _ in
            ZStack {
                if let p = service.currentPosition(finger: 0) {
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 18, height: 18)
                        .position(x: CGFloat(p.x) / surfaceWidth * size.width,
                                  y: CGFloat(p.y) / surfaceHeight * size.height)
                        .shadow(color: .mint.opacity(0.6), radius: 6)
                }
                if let p = service.currentPosition(finger: 1) {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 14, height: 14)
                        .position(x: CGFloat(p.x) / surfaceWidth * size.width,
                                  y: CGFloat(p.y) / surfaceHeight * size.height)
                        .shadow(color: .cyan.opacity(0.5), radius: 5)
                }
            }
        }
        // The dots cover the whole panel so the TimelineView's frame
        // matches; otherwise it would size to the implicit Circle
        // bounding box and clip dots near the edges.
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// MARK: - Moving and resizing rectangle regions

/// What a drag on a rectangle region drawing does, decided where it starts:
/// on a corner of the selected region it resizes it, inside a region it
/// moves it, and on empty space it draws a new one.
enum RectRegionDrag: Equatable {
    case draw
    case move(TouchpadRegion)
    case resize(TouchpadRegion, corner: Int)   // 0 top left, 1 top right, 2 bottom left, 3 bottom right

    /// How close to a corner, in points, a press counts as on it.
    static let handleReach: CGFloat = 9

    static func mode(at p: CGPoint, size: CGSize, regions: [TouchpadRegion], selected: UUID?) -> RectRegionDrag {
        guard size.width > 0, size.height > 0 else { return .draw }
        if let id = selected, let r = regions.first(where: { $0.id == id }) {
            for (i, c) in corners(r, size: size).enumerated() where hypot(c.x - p.x, c.y - p.y) <= handleReach {
                return .resize(r, corner: i)
            }
        }
        let x = Double(p.x / size.width), y = Double(p.y / size.height)
        // The top one where two overlap: the last drawn.
        if let hit = regions.last(where: { x >= $0.minX && x <= $0.maxX && y >= $0.minY && y <= $0.maxY }) {
            return .move(hit)
        }
        return .draw
    }

    static func corners(_ r: TouchpadRegion, size: CGSize) -> [CGPoint] {
        [CGPoint(x: r.minX * size.width, y: r.minY * size.height), CGPoint(x: r.maxX * size.width, y: r.minY * size.height),
         CGPoint(x: r.minX * size.width, y: r.maxY * size.height), CGPoint(x: r.maxX * size.width, y: r.maxY * size.height)]
    }

    /// The region as the drag leaves it, kept on the surface and at least
    /// a few percent across.
    func apply(from start: CGPoint, to current: CGPoint, size: CGSize) -> TouchpadRegion? {
        let dx = Double((current.x - start.x) / max(1, size.width))
        let dy = Double((current.y - start.y) / max(1, size.height))
        let minSide = 0.04
        switch self {
        case .draw:
            return nil
        case .move(var r):
            let w = r.maxX - r.minX, h = r.maxY - r.minY
            let nx = min(max(0, r.minX + dx), 1 - w), ny = min(max(0, r.minY + dy), 1 - h)
            r.minX = nx; r.maxX = nx + w; r.minY = ny; r.maxY = ny + h
            return r
        case .resize(var r, let corner):
            if corner == 0 || corner == 2 { r.minX = min(max(0, r.minX + dx), r.maxX - minSide) }
            else { r.maxX = max(min(1, r.maxX + dx), r.minX + minSide) }
            if corner == 0 || corner == 1 { r.minY = min(max(0, r.minY + dy), r.maxY - minSide) }
            else { r.maxY = max(min(1, r.maxY + dy), r.minY + minSide) }
            return r
        }
    }

    /// A copy a little down and right of the original, still on the surface.
    static func duplicate(_ r: TouchpadRegion, name: String, colorIndex: Int) -> TouchpadRegion {
        var copy = r
        copy.id = UUID()
        copy.name = name
        copy.colorIndex = colorIndex
        let w = r.maxX - r.minX, h = r.maxY - r.minY
        let nx = min(r.minX + 0.04, 1 - w), ny = min(r.minY + 0.04, 1 - h)
        copy.minX = nx; copy.maxX = nx + w; copy.minY = ny; copy.maxY = ny + h
        return copy
    }
}

/// The selected region's corners: the dots a drag resizes it by.
struct RegionCornerHandles: View {
    let rect: CGRect
    let color: Color

    var body: some View {
        ForEach(0..<4, id: \.self) { i in
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(color, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .position(x: i % 2 == 0 ? rect.minX : rect.maxX, y: i < 2 ? rect.minY : rect.maxY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
