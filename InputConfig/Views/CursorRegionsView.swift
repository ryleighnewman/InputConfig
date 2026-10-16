import SwiftUI
import AppKit

/// Editor for a preset's screen regions: rectangles on a display that a
/// Screen region input fires from while the pointer is inside, whatever is
/// moving the pointer (the Mac's trackpad, a mouse, a stick, the gyro).
///
/// This is deliberately not the touchpad editor. A touchpad zone is a place
/// on a controller's own pad, read from its fingers; a screen region is a
/// place on a display, read from the pointer. The two used to share one
/// sheet with the Mac's trackpad listed as a kind of touchpad, which is how
/// they came to be confused.
///
/// A region belongs either to every display or to one particular display,
/// chosen here. A region for the built-in screen is silent on an external
/// monitor and is drawn in that screen's own shape.
///
/// Mirrors the interaction model of the touchpad editor: an explicit Add
/// drawing mode, a motionless canvas with a small live pointer dot, canvas
/// on the left and the region list on the right, sixteen regions at most.
struct CursorRegionsView: View {
    @ObservedObject private var svc = CursorRegionService.shared
    @ObservedObject private var externalInput = ExternalInputDeviceService.shared

    /// Drives the live pointer dot while this view is visible.
    private let cursorPollTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale

    /// Opened from a screen region row: the display that region belongs to,
    /// shown alone (nil is every display), with no display menu.
    var startDisplay: DisplayKey? = nil
    var locked = false
    /// Drawn inside the editor's Zones section: no title and no Done.
    var embedded = false

    // MARK: - State

    /// The display the canvas represents and new regions belong to. Nil
    /// is "every display": the canvas then follows the pointer's display.
    @State private var chosenDisplay: DisplayKey?

    @State private var selectedRegionID: UUID?
    @State private var drawingNewRegion = false
    /// What the drag under way does: draw, move or resize.
    @State private var dragMode: RectRegionDrag?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var renamingRegionID: UUID?
    /// The region whose Delete waits for its confirmation.
    @State private var pendingDeleteRegionID: UUID?
    /// Rename puts the cursor in the field, so typing starts at once.
    @FocusState private var renameFocused: Bool
    @State private var renamingText: String = ""

    private static let maxRegions = 16

    private var regions: [TouchpadRegion] { svc.regions }

    /// The display the canvas is showing right now.
    private var shownDisplay: DisplayKey? { chosenDisplay ?? svc.currentDisplay }

    /// Regions that count on the shown display: every-display ones plus
    /// that display's own.
    private var regionsOnCanvas: [TouchpadRegion] {
        regions.filter { $0.display == nil || $0.display == shownDisplay }
    }

    /// The pointer dot is only true when the pointer is on the display the
    /// canvas shows.
    private var pointerIsOnShownDisplay: Bool {
        chosenDisplay == nil || chosenDisplay == svc.currentDisplay
    }

    // MARK: - Body

    /// The display's picture: this wide, as tall as the display's shape.
    private var canvasWidth: CGFloat { (embedded ? 380 : 440) * min(1.5, max(1, textScale)) }
    private var canvasHeight: CGFloat { canvasWidth / max(0.5, canvasAspectRatio) }

    var body: some View {
        VStack(alignment: .leading, spacing: embedded ? 10 : 12) {
            // In the editor the display row sits inside the same width as the
            // rest, so the whole editor centers like the stick's and the
            // touchpad's; spread across the card it pulled everything left.
            if !embedded { header }
            mainContent
        }
        .padding(embedded ? 0 : 20)
        // As big as what it shows: the display's picture and the list beside it.
        .fixedSize(horizontal: !embedded, vertical: !embedded)
        .onAppear {
            if locked { chosenDisplay = startDisplay }
            CursorRegionService.shared.beginTracking()
        }
        .onDisappear { CursorRegionService.shared.endTracking() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if !embedded {
                    Image(systemName: "rectangle.dashed")
                        .foregroundStyle(.tint)
                    Text("Screen Regions")
                        .font(.headline)
                }
                if locked {
                    Text(chosenDisplay.map { $0.name } ?? String(localized: "Every display"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else {
                    displayMenu
                }
                Text(displayHint)
                    .font(.caption)
                    .foregroundStyle(.hint)
                    .lineLimit(1)
                Spacer(minLength: 16)
                if !embedded {
                // No Return shortcut: it took Return from the rename and
                // bounds fields and closed the sheet. Escape closes it.
                Button("Done") { dismiss() }
                    .buttonStyle(.solidCompact)
                    // Escape backs out of a rename or a drawing first; the
                    // shortcut is taken before the field hears it.
                    .closesOnEscape {
                        if renamingRegionID != nil { cancelRename() }
                        else if drawingNewRegion { drawingNewRegion = false; dragStart = nil; dragCurrent = nil }
                        else { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Main layout

    @ViewBuilder
    private var mainContent: some View {
        if embedded { embeddedContent } else { sheetContent }
    }

    /// Laid out as the Adjust live sheet and the stick's Regions are: the
    /// display, the buttons under it, then the list and the live readings.
    private var embeddedContent: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                header
                regionsPanel
                    .frame(width: canvasWidth, height: canvasHeight)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(regions.count) / \(Self.maxRegions) regions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        addRegion(minX: 0.35, maxX: 0.65, minY: 0.35, maxY: 0.65)
                    } label: {
                        Label("Add Region", systemImage: "plus")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .fixedSize()
                    .disabled(regions.count >= Self.maxRegions)
                    .help("Adds a region in the middle; or drag on the drawing to draw one")
                }
            }
            .frame(width: canvasWidth)
            VStack(alignment: .leading, spacing: 12) {
                Text(RegionEditorHint.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                regionsList
                HStack(spacing: 20) {
                    statBlock("Pointer", pointerOnly)
                    statBlock("In region", pressedNames.isEmpty ? String(localized: "None") : pressedNames.formatted(.list(type: .and)))
                    statBlock("Trackpad pressure", externalInput.trackpadPressureStage >= 2
                              ? String(localized: "Deep")
                              : DeadzoneCalibrationView.percent(Double(min(max(externalInput.trackpadPressure, 0), 1))))
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 320 * min(1.5, max(1, textScale)), alignment: .leading)
        }
    }

    private var pressedNames: [String] { regionsOnCanvas.filter { svc.isRegionPressed($0.id) }.map(\.shownName) }

    private func statBlock(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var sheetContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                regionsPanel
                    .frame(width: canvasWidth, height: canvasHeight)

                HStack {
                    Button {
                        addRegion(minX: 0.35, maxX: 0.65, minY: 0.35, maxY: 0.65)
                    } label: {
                        Label("Add Region", systemImage: "plus")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(regions.count >= Self.maxRegions)
                    .help("Adds a region in the middle; or drag on the drawing to draw one")

                    Spacer(minLength: 8)

                    Text(cursorReadout)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.hint)

                    Text("\(regions.count) / \(Self.maxRegions) regions")
                        .font(.caption)
                        .foregroundStyle(.hint)
                }
                .frame(width: canvasWidth)
            }

            regionsList
                .frame(width: 230, height: max(220, canvasHeight + 30), alignment: .topLeading)
        }
    }

    /// Which display the canvas shows and new regions belong to.
    private var displayMenu: some View {
        Menu {
            Button {
                chosenDisplay = nil
            } label: {
                if chosenDisplay == nil { Label("Every display", systemImage: "checkmark") } else { Text("Every display") }
            }
            Divider()
            ForEach(svc.attachedDisplays) { d in
                Button {
                    chosenDisplay = d.key
                } label: {
                    if chosenDisplay == d.key { Label(d.key.name, systemImage: "checkmark") } else { Text(d.key.name) }
                }
            }
            // Displays that regions refer to but are not attached now.
            let absent = storedDisplays.filter { !svc.isDisplayAttached($0) }
            if !absent.isEmpty {
                Divider()
                ForEach(absent, id: \.self) { d in
                    Button {
                        chosenDisplay = d
                    } label: {
                        Text("\(d.name) (not connected)")
                    }
                }
            }
        } label: {
            Text(chosenDisplay.map { $0.name } ?? String(localized: "Every display"))
        }
        .fixedSize()
        .help("New regions belong to this display. Every display means the same area of whichever screen the pointer is on.")
    }

    private var displayHint: String {
        if let d = chosenDisplay {
            return svc.isDisplayAttached(d) ? String(localized: "regions here fire only on this display") : String(localized: "not connected; shown at a guessed shape")
        }
        return svc.screenCount > 1 ? String(localized: "the same area on any of \(svc.screenCount) displays") : String(localized: "the same area on any display")
    }

    /// Every display any region refers to.
    private var storedDisplays: [DisplayKey] {
        var out: [DisplayKey] = []
        for r in regions { if let d = r.display, !out.contains(d) { out.append(d) } }
        return out
    }

    // MARK: - Canvas

    /// A picture of the surface: left is left in every language.
    private var regionsPanel: some View { regionsPanelDrawing.environment(\.layoutDirection, .leftToRight) }

    private var regionsPanelDrawing: some View {
        GeometryReader { geo in
            ZStack {
                // The surface as the Adjust live sheet draws a trigger's bar.
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)

                ForEach(regionsOnCanvas) { region in
                    let isPressed = svc.isRegionPressed(region.id)
                    let isSelected = region.id == selectedRegionID
                    let rect = CGRect(
                        x: region.minX * geo.size.width,
                        y: region.minY * geo.size.height,
                        width: (region.maxX - region.minX) * geo.size.width,
                        height: (region.maxY - region.minY) * geo.size.height)
                    let color = paletteColor(at: region.colorIndex)
                    // Lit and picked as the stick's and the trigger's regions are.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(isPressed ? 0.32 : (isSelected ? 0.2 : 0.06)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(color.opacity(isPressed || isSelected ? 1 : 0.8),
                                        style: StrokeStyle(lineWidth: isPressed || isSelected ? 2.5 : 1,
                                                           dash: region.display == nil ? [] : [5, 3]))
                        )
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
                        .onTapGesture {
                            if !drawingNewRegion { selectedRegionID = region.id }
                        }
                        .contextMenu {
                            Button("Rename") {
                                selectedRegionID = region.id
                                renamingRegionID = region.id
                                renamingText = region.shownName
                                DispatchQueue.main.async { renameFocused = true }
                            }
                            Button("Duplicate") { duplicate(region) }
                                .disabled(regions.count >= Self.maxRegions)
                            Divider()
                            Button("Delete\u{2026}", role: .destructive) { pendingDeleteRegionID = region.id }
                        }
                        .help(region.display == nil ? String(localized: "\(region.shownName): every display") : String(localized: "\(region.shownName): \(region.display!.name) only"))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(region.shownName)
                        .accessibilityValue(canvasRegionValue(region, isPressed: isPressed))
                        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                        .accessibilityAction { if !drawingNewRegion { selectedRegionID = region.id } }
                }

                // Live pointer dot, in the same normalized space the regions
                // hit-test against, only when the pointer is on this display.
                // The live dot the Adjust live sheet draws.
                if pointerIsOnShownDisplay {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .shadow(color: Color.accentColor.opacity(0.5), radius: 4)
                        .position(x: svc.cursorNormalized.x * geo.size.width,
                                  y: svc.cursorNormalized.y * geo.size.height)
                        .allowsHitTesting(false)
                }

                // Which display the canvas represents; the editor names it above.
                if !embedded {
                Text(shownDisplay?.name ?? String(localized: "Display"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.4)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                    .allowsHitTesting(false)
                }

                // Live Force Touch pressure while pressing the Mac trackpad
                // over this window, bindable as Pressure and Deep Press on
                // the Mouse input type. The editor shows it under the display.
                if !embedded {
                HStack(spacing: 5) {
                    Image(systemName: "hand.tap.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    ProgressView(value: Double(min(max(externalInput.trackpadPressure, 0), 1)))
                        .frame(width: 64)
                    Text(externalInput.trackpadPressureStage >= 2
                         ? String(localized: "Deep")
                         : String(format: "%.0f%%", externalInput.trackpadPressure * 100))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 34, alignment: .leading)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.4)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Trackpad pressure")
                .accessibilityValue(externalInput.trackpadPressureStage >= 2
                                    ? String(localized: "Deep press")
                                    : String(localized: "\(Int(externalInput.trackpadPressure * 100)) percent"))
                }

                if let id = selectedRegionID, let r = regionsOnCanvas.first(where: { $0.id == id }) {
                    RegionCornerHandles(rect: CGRect(x: r.minX * geo.size.width, y: r.minY * geo.size.height,
                                                     width: (r.maxX - r.minX) * geo.size.width,
                                                     height: (r.maxY - r.minY) * geo.size.height),
                                        color: paletteColor(at: r.colorIndex))
                }

                if drawingNewRegion, let start = dragStart, let current = dragCurrent {
                    let r = CGRect(
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y))
                    Rectangle()
                        .fill(Color.yellow.opacity(0.25))
                        .overlay(Rectangle().stroke(Color.yellow,
                                                    style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(size: geo.size),
                     including: .gesture)
            .onReceive(cursorPollTimer) { _ in
                svc.pollCursorOnce()
                ExternalInputDeviceService.shared.ensurePressureMetricsMonitor()
            }
        }
    }

    // MARK: - Region list

    /// The list, then typed bounds for the selected region: placing and
    /// sizing one took a pointer drag before, so keyboard, switch and
    /// VoiceOver users could only make a fixed box in the middle.
    private var regionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            regionsListBody
            if let id = selectedRegionID, let region = svc.region(with: id) {
                // Only while the region is still there: committing after it
                // was deleted would add it back.
                RegionBoundsFields(region: region) { updated in
                    guard svc.region(with: updated.id) != nil else { return }
                    svc.upsert(updated)
                }
                .id(region.id)
            }
        }
    }

    private var regionsListBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Regions")
                .font(embedded ? .subheadline : .caption.weight(.semibold))
                .foregroundStyle(embedded ? .primary : .secondary)
                .accessibilityAddTraits(.isHeader)
            if regionsOnCanvas.isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !embedded { Spacer() }
            } else if embedded {
                // The editor scrolls; a list of its own would scroll inside it.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(regionsOnCanvas) { region in
                        regionRow(region)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(regionsOnCanvas) { region in
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
        let isPressed = svc.isRegionPressed(region.id)
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            if renamingRegionID == region.id {
                TextField("Name", text: $renamingText, onCommit: {
                    commitRename(for: region.id)
                })
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Rename region")
                .focused($renameFocused)
                .onExitCommand { cancelRename() }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(region.shownName)
                        .font(.body)
                        .lineLimit(1)
                    Text(displayTag(for: region))
                        .font(.caption2)
                        .foregroundStyle(.hint)
                        .lineLimit(1)
                }
                Spacer()
            }
            if isPressed {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            Menu {
                // Selecting shows the typed bounds; this menu is reachable by keyboard.
                Button("Select") {
                    selectedRegionID = region.id
                    if let d = region.display, d != chosenDisplay { chosenDisplay = d }
                }
                Button("Rename") {
                    renamingRegionID = region.id
                    renamingText = region.shownName
                    DispatchQueue.main.async { renameFocused = true }
                }
                Button("Duplicate") { duplicate(region) }
                    .disabled(regions.count >= Self.maxRegions)
                Menu("Display") {
                    Button {
                        setDisplay(nil, for: region.id)
                    } label: {
                        if region.display == nil { Label("Every display", systemImage: "checkmark") } else { Text("Every display") }
                    }
                    ForEach(svc.attachedDisplays) { d in
                        Button {
                            setDisplay(d.key, for: region.id)
                        } label: {
                            if region.display == d.key { Label(d.key.name, systemImage: "checkmark") } else { Text(d.key.name) }
                        }
                    }
                }
                Button("Delete\u{2026}", role: .destructive) {
                    pendingDeleteRegionID = region.id
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Region options for \(region.shownName)")
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
            // Jump the canvas to the display this region lives on.
            if let d = region.display, d != chosenDisplay { chosenDisplay = d }
        }
        // Contain, as in Stick zones: the row's options menu (the only
        // Rename, Display and Delete) stays its own element.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(region.shownName), \(displayTag(for: region))")
        .accessibilityValue([isSelected ? String(localized: "Selected") : nil, isPressed ? String(localized: "Active") : nil]
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

    private func displayTag(for region: TouchpadRegion) -> String {
        guard let d = region.display else { return String(localized: "Every display") }
        return svc.isDisplayAttached(d) ? d.name : String(localized: "\(d.name) (not connected)")
    }

    // MARK: - Drawing

    /// A drag on a selected region's corner resizes it, inside a region
    /// moves it, and on empty display draws a new one: no mode to enter first.
    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                let mode = dragMode ?? RectRegionDrag.mode(at: value.startLocation, size: size,
                                                          regions: regionsOnCanvas, selected: selectedRegionID)
                dragMode = mode
                if mode != .draw {
                    if let changed = mode.apply(from: value.startLocation, to: value.location, size: size) {
                        svc.upsert(changed)
                        selectedRegionID = changed.id
                    }
                    return
                }
                guard regions.count < Self.maxRegions else { return }
                drawingNewRegion = true
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                defer { dragMode = nil }
                if let mode = dragMode, mode != .draw { return }
                guard drawingNewRegion, let start = dragStart else { return }
                let end = value.location
                let normMinX = max(0, min(1, Double(min(start.x, end.x) / size.width)))
                let normMaxX = max(0, min(1, Double(max(start.x, end.x) / size.width)))
                let normMinY = max(0, min(1, Double(min(start.y, end.y) / size.height)))
                let normMaxY = max(0, min(1, Double(max(start.y, end.y) / size.height)))
                if (normMaxX - normMinX) > 0.04 && (normMaxY - normMinY) > 0.04 {
                    addRegion(minX: normMinX, maxX: normMaxX,
                              minY: normMinY, maxY: normMaxY)
                }
                drawingNewRegion = false
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func addRegion(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let count = regions.count
        let name = String(localized: "Region \(count + 1)").withoutRTLMark
        let colorIndex = count % TouchpadRegion.colorPalette.count
        let region = TouchpadRegion(name: name, minX: minX, maxX: maxX,
                                     minY: minY, maxY: maxY, colorIndex: colorIndex,
                                     display: chosenDisplay)
        svc.upsert(region)
        selectedRegionID = region.id
    }

    /// A copy beside the original, on the same display.
    private func duplicate(_ region: TouchpadRegion) {
        guard regions.count < Self.maxRegions else { return }
        let copy = RectRegionDrag.duplicate(region, name: String(localized: "Region \(regions.count + 1)").withoutRTLMark,
                                            colorIndex: regions.count % TouchpadRegion.colorPalette.count)
        svc.upsert(copy)
        selectedRegionID = copy.id
    }

    private func setDisplay(_ key: DisplayKey?, for id: UUID) {
        guard var region = svc.region(with: id) else { return }
        region.display = key
        svc.upsert(region)
    }

    private func deleteRegion(_ id: UUID) {
        if selectedRegionID == id { selectedRegionID = nil }
        svc.deleteRegion(id)
    }

    private func commitRename(for id: UUID) {
        let trimmed = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, var region = svc.region(with: id), trimmed != region.shownName {
            region.name = trimmed
            svc.upsert(region)
        }
        renamingRegionID = nil
        renamingText = ""
    }

    private func cancelRename() {
        renamingRegionID = nil
        renamingText = ""
    }

    private func canvasRegionValue(_ region: TouchpadRegion, isPressed: Bool) -> String {
        let x = Int(region.minX * 100)
        let y = Int(region.minY * 100)
        let w = Int((region.maxX - region.minX) * 100)
        let h = Int((region.maxY - region.minY) * 100)
        var value = String(localized: "Positioned at \(x) percent across, \(y) percent down, \(w) by \(h) percent of the display, \(displayTag(for: region))")
        if isPressed { value += String(localized: ", active") }
        return value
    }

    // MARK: - Helpers

    /// The shape of the display the canvas shows: the chosen one's, or the
    /// pointer's, or 16:10 for a display that is not attached.
    private var canvasAspectRatio: CGFloat {
        if let d = chosenDisplay {
            return svc.attachedDisplays.first(where: { $0.key == d })?.aspect ?? 16.0 / 10.0
        }
        return svc.currentScreenAspect
    }

    /// The pointer's place alone, under its "Pointer" heading.
    private var pointerOnly: String {
        guard pointerIsOnShownDisplay else { return String(localized: "On another display") }
        let p = svc.cursorNormalized
        return "\(DeadzoneCalibrationView.percent(Double(p.x))), \(DeadzoneCalibrationView.percent(Double(p.y)))"
    }

    private var cursorReadout: String {
        guard pointerIsOnShownDisplay else { return String(localized: "Pointer on another display") }
        let p = svc.cursorNormalized
        return String(localized: "Pointer: \(String(format: "%.0f%%", p.x * 100)), \(String(format: "%.0f%%", p.y * 100))")
    }

    private func paletteColor(at index: Int) -> Color {
        regionPaletteColor(at: index)
    }
}


/// A region's place and size as typed numbers, in percent of the area it is
/// drawn on: left and top edge, width and height. Kept inside the area and
/// at least 4 percent each way, as a drawn region is.
struct RegionBoundsFields: View {
    let region: TouchpadRegion
    let save: (TouchpadRegion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Place and size, in percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                field(String(localized: "Left"), value: region.minX) { set(minX: $0) }
                field(String(localized: "Top"), value: region.minY) { set(minY: $0) }
                field(String(localized: "Width"), value: region.maxX - region.minX) { set(width: $0) }
                field(String(localized: "Height"), value: region.maxY - region.minY) { set(height: $0) }
            }
        }
    }

    private func field(_ label: String, value: Double, apply: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, value: SwiftUI.Binding(
                get: { Int((value * 100).rounded()) },
                set: { apply(Double($0) / 100) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 52)
                .accessibilityLabel("\(label) of \(region.shownName), percent")
        }
    }

    private func set(minX: Double? = nil, minY: Double? = nil, width: Double? = nil, height: Double? = nil) {
        var r = region
        let w = max(0.04, min(1, width ?? (r.maxX - r.minX)))
        let h = max(0.04, min(1, height ?? (r.maxY - r.minY)))
        let x = max(0, min(1 - w, minX ?? r.minX))
        let y = max(0, min(1 - h, minY ?? r.minY))
        r.minX = x; r.maxX = x + w
        r.minY = y; r.maxY = y + h
        save(r)
    }
}
