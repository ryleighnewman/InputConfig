import SwiftUI
import GameController

/// Lets the user define zones on a joystick stick's X/Y plane, as
/// rectangles or as ring sectors (between two distances from the center
/// and two directions), and bands on one axis's travel (a trigger pulled
/// past half way, a throttle's top third). Mirrors the layout of `CursorRegionsView` and
/// `TouchpadCalibrationView`'s region editor but the canvas
/// represents the stick's deflection range (a square with a small
/// circular guide hinting at the physical stick's circular travel).
///
/// Coordinate convention: the canvas is 0...1 in both axes, mapped to
/// the stick's -1...1 axis values at the service layer. Y=0 is up.
struct StickRegionsView: View {
    @ObservedObject private var svc = StickRegionService.shared
    @EnvironmentObject private var controllerService: GameControllerService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale

    /// Where to open: a stick (0, 1) or an axis's bands (100 plus the axis).
    var startKey: Int? = nil
    /// The controller the live dot and travel line read: the row's own.
    var slot: Int = 0
    /// Drawn inside the editor's Zones section, which names the part: no
    /// title, no Done, no padding of its own.
    var embedded = false
    /// The rows that read this stick or trigger, in the editor: their
    /// deadzones are drawn on it and each one is listed, a click away.
    var partRows: [RegionPartRow] = []
    var onJumpToRow: ((UUID) -> Void)? = nil
    /// A DualSense or DualSense Edge group: its triggers' feel in this
    /// preset (0 off, 1 light, 2 medium, 3 firm), and how to change it.
    var triggerFeel: (left: Int, right: Int) = (0, 0)
    var onSetTriggerFeel: ((_ left: Bool, _ level: Int) -> Void)? = nil

    @State private var selectedStick: Int = 0  // 0 = left, 1 = right, 2 = an axis's travel
    /// The axis whose bands are shown when `selectedStick` is 2.
    @State private var bandAxis: Int = 4
    /// What Add Region draws on a stick.
    /// What drawing makes on a stick: always a ring, part of the stick's
    /// travel between two distances and two directions. A rectangle on a
    /// round stick made no sense; ones made before stay as they are.
    @State private var newShape: ZoneShape = .ring

    enum ZoneShape: Hashable { case rectangle, ring }

    /// The key the shown zones live under: a stick, or an axis's bands.
    private var regionKey: Int {
        selectedStick == 2 ? StickRegionService.bandKeyBase + bandAxis : selectedStick
    }
    private var showsBands: Bool { selectedStick == 2 }

    /// Axes a band can be put on: the triggers first, then each stick
    /// direction, then the extra axes a wheel, throttle or pedal set has.
    static let bandAxes: [Int] = [4, 5, 0, 1, 2, 3] + Array(6..<16)
    @State private var selectedRegionID: UUID?

    @State private var drawingNewRegion = false
    /// What the drag under way does: draw, move or reshape.
    @State private var dragMode: StickRegionDrag?
    /// The region under the pointer, for its right-click menu.
    @State private var hoverRegionID: UUID?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    #if DEBUG
    /// Marketing capture: a drawing in progress and the pointer, in fractions
    /// of the drawing (see MarketingRegionHooks). DEBUG only.
    @State private var debugDraw: [Double]?
    @State private var debugCursor: [Double]?
    #endif

    @State private var renamingRegionID: UUID?
    /// The region whose Delete waits for its confirmation.
    @State private var pendingDeleteRegionID: UUID?
    @FocusState private var renameFocused: Bool
    @State private var renamingText: String = ""

    /// Live stick position, polled at 30 Hz so the binding-editor
    /// preview can show where the connected controller's stick is
    /// sitting right now. Only updates while at least one controller
    /// is connected; otherwise stays at (0.5, 0.5) i.e. center.
    @State private var liveStickPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var liveStickActive: Bool = false
    /// The shown axis's reading as a fraction of its travel, for bands.
    @State private var liveFraction: Double = 0
    @State private var pollTimer: Timer?
    /// The live stick in the app's axes, and its recent path, for the plot.
    @State private var liveX: Float = 0
    @State private var liveY: Float = 0
    @State private var trail: [(x: Float, y: Float)] = []

    private static let maxRegions = 16

    #if DEBUG
    /// The debug hook's starting tab: "0", "1", "2", or "ring".
    nonisolated(unsafe) static var debugStart: String?
    #endif

    /// Opened on one stick or one trigger (a row, the Live Visualizer, the
    /// deadzone sheet): only that one is shown, named in the title. From
    /// the app's own menus, the title is a menu that picks which.
    private var locked: Bool { startKey != nil }

    /// Text Size above Default grows the drawing and the list with the text.
    private var scale: CGFloat { min(1.6, max(1, textScale)) }

    var body: some View {
        Group {
            if embedded {
                mainContent
                    .onReceive(NotificationCenter.default.publisher(for: .inputConfigTourSelectRegion)) { note in
                        let list = svc.regions(forStick: regionKey)
                        let i = note.object as? Int ?? 0
                        selectedRegionID = list.indices.contains(i) ? list[i].id : nil
                    }
                    #if DEBUG
                    .modifier(MarketingRegionHooks(draw: $debugDraw, cursor: $debugCursor) { i in
                        let list = svc.regions(forStick: regionKey)
                        selectedRegionID = list.indices.contains(i) ? list[i].id : nil
                    })
                    #endif
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    mainContent
                    footer
                }
                .padding(20)
                // As big as what it shows.
                .fixedSize()
            }
        }
        .onAppear {
            #if DEBUG
            switch Self.debugStart {
            case "1": selectedStick = 1
            case "2": selectedStick = 2
            case "ring": newShape = .ring
            default: break
            }
            Self.debugStart = nil
            #endif
            if let key = startKey {
                if StickRegionService.isBandKey(key) {
                    selectedStick = 2; bandAxis = key - StickRegionService.bandKeyBase
                } else {
                    selectedStick = key == 1 ? 1 : 0
                }
            }
            startPolling()
        }
        .onDisappear(perform: stopPolling)
        // The other stick's selection, rename and drawing do not carry over
        // to one that does not show them.
        .onChange(of: regionKey) { _, _ in
            selectedRegionID = nil; renamingRegionID = nil
            drawingNewRegion = false; dragStart = nil; dragCurrent = nil
            trail.removeAll()
        }
    }

    /// What the sheet is showing: "Left stick zones", "Left trigger zones".
    private var targetTitle: String {
        if showsBands { return String(localized: "\(StickRegionService.axisDisplayName(bandAxis)) regions") }
        return selectedStick == 1 ? String(localized: "Right stick regions") : String(localized: "Left stick regions")
    }

    private var header: some View {
        HStack(spacing: 10) {
            if locked {
                Text(targetTitle)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            } else {
                targetMenu
            }
            Spacer(minLength: 16)
        }
    }

    /// From the app's menus: the title picks the stick or the trigger.
    private var targetMenu: some View {
        Menu {
            Button(String(localized: "Left stick regions")) { selectedStick = 0 }
            Button(String(localized: "Right stick regions")) { selectedStick = 1 }
            Divider()
            ForEach([4, 5], id: \.self) { axis in
                Button(bandAxisMenuName(axis)) { bandAxis = axis; selectedStick = 2 }
            }
            Menu("Other axes") {
                ForEach(Self.bandAxes.filter { $0 != 4 && $0 != 5 }, id: \.self) { axis in
                    Button(bandAxisMenuName(axis)) { bandAxis = axis; selectedStick = 2 }
                }
            }
        } label: {
            Text(targetTitle)
                .font(.title2.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(targetTitle)
        .accessibilityInputLabels([Text(targetTitle), Text("Stick")])
    }

    /// Laid out as the Adjust live sheet is, with its drawings: the hint,
    /// the stick or trigger, the button under it, then the list, the rows
    /// and the live readings. The two must never look like different tools.
    /// The drawing on the left with its count and Add Region under it; on
    /// the right one line on how to draw, the regions, the rows on this
    /// part and the live readings. Side by side, so the card's width is
    /// used rather than one tall stack.
    private var mainContent: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 10) {
                if showsBands { bandPanel } else { regionsPanel }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(svc.regions(forStick: regionKey).count) / \(Self.maxRegions) regions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Region count")
                        .accessibilityValue("\(svc.regions(forStick: regionKey).count) of \(Self.maxRegions) regions defined")
                    Spacer(minLength: 0)
                    Button {
                        addCenteredRegion()
                    } label: {
                        Label("Add Region", systemImage: "plus")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .fixedSize()
                    .disabled(svc.regions(forStick: regionKey).count >= Self.maxRegions)
                    .help("Adds a region in the middle; or drag on the drawing to draw one")
                }
            }
            .frame(width: showsBands ? 90 + 16 + 110 : plotSize)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RegionEditorHint.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(RegionEditorHint.purpose(showsBands ? .trigger : .stick))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A DualSense trigger's feel, the preset's own setting, next
                // to the trigger's regions where a pull is set up.
                if showsBands, (bandAxis == 4 || bandAxis == 5), let onSetTriggerFeel {
                    triggerFeelControl(left: bandAxis == 4, set: onSetTriggerFeel)
                }
                regionsList
                HStack(spacing: 20) {
                    statBlocks
                    Spacer(minLength: 0)
                    if !showsBands { resetTrailButton }
                }
                if !liveStickActive {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Connect a controller to see live input.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 320 * scale, alignment: .leading)
        }
    }

    private func triggerFeelControl(left: Bool, set: @escaping (Bool, Int) -> Void) -> some View {
        let level = left ? triggerFeel.left : triggerFeel.right
        return VStack(alignment: .leading, spacing: 4) {
            Text("Trigger feel")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Trigger feel", selection: Binding(get: { level }, set: { set(left, $0) })) {
                ForEach(0...3, id: \.self) { Text(TriggerFeelName.name($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            Text("The DualSense's resistance across the pull while this preset runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The live readings, as the Adjust live sheet shows them.
    @ViewBuilder
    private var statBlocks: some View {
        statBlock("Current", DeadzoneCalibrationView.percent(liveAmount))
        statBlock("In region", occupiedRegion?.shownName ?? String(localized: "None"))
    }

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

    private var resetTrailButton: some View {
        Button {
            trail.removeAll()
        } label: {
            Label("Reset Trail", systemImage: "arrow.counterclockwise")
                .font(.caption)
        }
        .buttonStyle(.solidSecondaryCompact)
        .controlSize(.small)
    }

    /// How far the stick is pushed, or the axis pulled, 0 to 1.
    private var liveAmount: Double {
        guard liveStickActive else { return 0 }
        if showsBands { return liveFraction }
        return min(1, Double(hypot(liveX, liveY)))
    }

    private var footer: some View {
        HStack {
            Spacer()
            // A click closes; Escape backs out of a rename or a drawing first.
            Button("Done") { dismiss() }
                .buttonStyle(.solid)
                .closesOnEscape {
                    if renamingRegionID != nil { renamingRegionID = nil }
                    else if drawingNewRegion { drawingNewRegion = false; dragStart = nil; dragCurrent = nil }
                    else { dismiss() }
                }
        }
    }

    // MARK: - Canvas

    /// The stick, drawn exactly as the Adjust live sheet draws it, with
    /// this preset's regions on it and the drawing layer on top.
    private var regionsPanel: some View {
        let size = plotSize
        let regions = svc.regions(forStick: regionKey)
        let inside = occupiedRegion?.id
        return StickPlot(size: size, x: liveX, y: liveY, trail: trail, showsDot: liveStickActive,
                         deadzones: rowDeadzones, fullPush: rowFullPush, zones: regions,
                         lit: { $0.id == inside }, selected: selectedRegionID) {
            drawingLayer(size: CGSize(width: size, height: size), regions: regions)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stick region canvas")
        .accessibilityValue(panelAccessibilityValue)
        .accessibilityHint("The stick's travel, the center at rest. Contains the defined regions and a live indicator of the connected stick's position.")
        // Non-drag path so keyboard and switch users can create and
        // remove regions without a pointer drag.
        .accessibilityAction(named: Text("Add region in the center")) {
            addCenteredRegion()
        }
        .accessibilityAction(named: Text("Delete selected region")) {
            // Asked first, as the row's Delete is.
            if let id = selectedRegionID { pendingDeleteRegionID = id }
        }
    }

    private var plotSize: CGFloat { 260 * scale }
    private var gaugeHeight: CGFloat { 240 * scale }

    /// What lies over the drawing: a click picks the region under it, a
    /// drag draws a new one, and each region is a VoiceOver element.
    private func drawingLayer(size: CGSize, regions: [TouchpadRegion]) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(drawGesture(size: size), including: .gesture)
                .simultaneousGesture(SpatialTapGesture().onEnded { pick(at: $0.location, size: size) })
                .onContinuousHover { phase in
                    let id: UUID?
                    if case .active(let p) = phase { id = regionID(at: p, size: size) } else { id = nil }
                    if id != hoverRegionID { hoverRegionID = id }
                }
                .contextMenu {
                    if let id = hoverRegionID, let region = regions.first(where: { $0.id == id }) {
                        regionMenuItems(region)
                    }
                }
            drawingPreview(size: size)
            // Where the tour's pointer lands before it selects the first region.
            if let first = regions.first, let at = labelPoint(first, size: size) {
                Color.clear
                    .frame(width: 24, height: 24)
                    .spotlightAnchor(SpotlightID.tourRegion)
                    .position(at)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // Each region's name on it, as the touchpad's and the screen's
            // drawings show theirs, where the region has room for it.
            ForEach(regions) { region in
                if let at = labelPoint(region, size: size) {
                    Text(region.shownName)
                        .font(.caption2)
                        .foregroundStyle(regionPaletteColor(at: region.colorIndex).opacity(0.9))
                        .lineLimit(1)
                        .fixedSize()
                        .position(at)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if let id = selectedRegionID, let r = regions.first(where: { $0.id == id }) {
                StickRegionHandles(points: handlePoints(r, size: size), color: regionPaletteColor(at: r.colorIndex))
            }
            ForEach(regions) { region in
                let box = region.drawnBox
                let rect = showsBands
                    ? CGRect(x: 5, y: (1 - region.maxY) * size.height, width: size.width - 10,
                             height: max(2, (region.maxY - region.minY) * size.height))
                    : CGRect(x: box.minX * size.width, y: box.minY * size.height,
                             width: box.width * size.width, height: box.height * size.height)
                regionElement(region, rect: rect)
            }
            #if DEBUG
            if let p = debugCursor { MarketingPointer(at: CGPoint(x: p[0] * size.width, y: p[1] * size.height)) }
            #endif
        }
        .frame(width: size.width, height: size.height)
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

    /// The region being drawn, dashed, until the drag ends.
    @ViewBuilder
    private func drawingPreview(size: CGSize) -> some View {
        if let (start, current) = previewPoints(size) {
            if showsBands {
                Rectangle()
                    .fill(Color.yellow.opacity(0.25))
                    .overlay(Rectangle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                    .frame(width: size.width - 10, height: abs(current.y - start.y))
                    .position(x: size.width / 2, y: (start.y + current.y) / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                let ring = ringFrom(start, current, size: size)
                let box = ring.boundingBox
                RingSectorShape(ring: ring)
                    .fill(Color.yellow.opacity(0.25), style: FillStyle(eoFill: true))
                    .overlay(RingSectorShape(ring: ring)
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                    .frame(width: max(1, box.width * size.width), height: max(1, box.height * size.height))
                    .position(x: box.midX * size.width, y: box.midY * size.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// A region as VoiceOver and Voice Control reach it; the pointer picks
    /// it through the layer under it.
    private func regionElement(_ region: TouchpadRegion, rect: CGRect) -> some View {
        let isSelected = region.id == selectedRegionID
        return Color.clear
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityAction { selectedRegionID = region.id }
            .accessibilityLabel(region.shownName)
            .accessibilityValue(showsBands ? bandExtentDescription(region) : regionExtentDescription(region))
            .accessibilityHint("Selects this region")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Where a region's name goes: the middle of a ring sector or of a
    /// band, the top-left of a rectangle. Nil when the region is too thin
    /// or too short for a caption.
    private func labelPoint(_ r: TouchpadRegion, size: CGSize) -> CGPoint? {
        if showsBands {
            let top = (1 - r.maxY) * size.height, h = (r.maxY - r.minY) * size.height
            guard h >= 16 else { return nil }
            // The middle of the band: its picked dots sit on its two ends.
            return CGPoint(x: size.width / 2, y: top + h / 2)
        }
        if let ring = r.ring {
            let half = size.width / 2
            let mid = (ring.inner + ring.outer) / 2
            let thickness = (ring.outer - ring.inner) * half
            let arc = mid * half * ring.span * .pi / 180
            guard thickness >= 13, arc >= 44 else { return nil }
            let deg = ring.span >= 360 ? 90 : ring.start + ring.span / 2
            let rad = deg * .pi / 180
            return CGPoint(x: half + mid * half * cos(rad), y: half - mid * half * sin(rad))
        }
        let w = (r.maxX - r.minX) * size.width, h = (r.maxY - r.minY) * size.height
        guard w >= 40, h >= 16 else { return nil }
        return CGPoint(x: r.minX * size.width + min(w / 2, 30), y: r.minY * size.height + 9)
    }

    /// The top region under a point of the drawing.
    private func regionID(at p: CGPoint, size: CGSize) -> UUID? {
        guard size.width > 0, size.height > 0 else { return nil }
        let regions = svc.regions(forStick: regionKey)
        if showsBands { return regions.last { $0.containsTravel(1 - Double(p.y / size.height)) }?.id }
        return regions.last { $0.contains(normalizedX: Double(p.x / size.width), y: Double(p.y / size.height)) }?.id
    }

    /// Where the selected region's handles are drawn.
    private func handlePoints(_ r: TouchpadRegion, size: CGSize) -> [CGPoint] {
        if showsBands {
            return [CGPoint(x: size.width / 2, y: (1 - r.minY) * size.height),
                    CGPoint(x: size.width / 2, y: (1 - r.maxY) * size.height)]
        }
        if let ring = r.ring { return StickRegionDrag.ringHandles(ring, size: size) }
        return RectRegionDrag.corners(r, size: size)
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
        Button("Duplicate") { duplicate(region) }
            .disabled(svc.regions(forStick: regionKey).count >= Self.maxRegions)
        Divider()
        Button("Delete\u{2026}", role: .destructive) { pendingDeleteRegionID = region.id }
    }

    /// A copy beside the original: a ring turned a little, a band above
    /// (or below) it, a rectangle down and to the right.
    private func duplicate(_ region: TouchpadRegion) {
        guard svc.regions(forStick: regionKey).count < Self.maxRegions else { return }
        let n = nextName()
        var copy: TouchpadRegion
        if var ring = region.ring {
            if ring.span < 360 { ring.start = RingSector.wrap(ring.start + 15); ring.end = RingSector.wrap(ring.end + 15) }
            copy = TouchpadRegion.ring(name: n.name, ring, colorIndex: n.colorIndex)
        } else if showsBands {
            let h = region.maxY - region.minY
            // Below the original, it stays clear of a released trigger.
            let low = region.maxY + h <= 1 ? region.maxY : max(0.01, region.minY - h)
            copy = TouchpadRegion.band(name: n.name, from: low, to: min(1, low + h), colorIndex: n.colorIndex)
        } else {
            copy = RectRegionDrag.duplicate(region, name: n.name, colorIndex: n.colorIndex)
        }
        svc.upsert(copy, stickIndex: regionKey)
        selectedRegionID = copy.id
    }

    /// A click on the drawing picks the region under it, the top one where
    /// two overlap; a click on empty travel clears the pick.
    private func pick(at p: CGPoint, size: CGSize) {
        guard !drawingNewRegion, size.width > 0, size.height > 0 else { return }
        let regions = svc.regions(forStick: regionKey)
        if showsBands {
            let f = 1 - Double(p.y / size.height)
            selectedRegionID = regions.last { $0.containsTravel(f) }?.id
        } else {
            let x = Double(p.x / size.width), y = Double(p.y / size.height)
            selectedRegionID = regions.last { $0.contains(normalizedX: x, y: y) }?.id
        }
    }

    // MARK: - Region list

    /// The list, then typed bounds for the selected region: placing and
    /// sizing one took a pointer drag before, so keyboard, switch and
    /// VoiceOver users could only make a fixed box in the middle.
    private var regionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            regionsListBody
            if !partRows.isEmpty { partRowsList }
            if let id = selectedRegionID, let found = svc.region(with: id) {
                // Only while the region is still there: committing after it
                // was deleted would add it back.
                let save: (TouchpadRegion) -> Void = { updated in
                    guard let current = svc.region(with: updated.id) else { return }
                    svc.upsert(updated, stickIndex: current.stickIndex)
                }
                Group {
                    if StickRegionService.isBandKey(found.stickIndex) {
                        BandBoundsFields(region: found.region, save: save)
                    } else if found.region.ring != nil {
                        RingBoundsFields(region: found.region, save: save)
                    } else {
                        RegionBoundsFields(region: found.region, save: save)
                    }
                }
                .id(found.region.id)
            }
        }
    }

    private var regionsListBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Regions")
                .font(.subheadline)
                .accessibilityAddTraits(.isHeader)
            if svc.regions(forStick: regionKey).isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(svc.regions(forStick: regionKey)) { region in
                        regionRow(region)
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
                Text(region.shownName)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
            }
            Menu {
                // Selecting shows the typed bounds, the way to place a
                // region without dragging; this menu is reachable by keyboard.
                Button("Select") { selectedRegionID = region.id }
                regionMenuItems(region)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(region.shownName)")
            .help("Select, rename, duplicate or delete")
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
        // Contain, not combine: combining swallowed the row's menu, the only
        // Rename and Delete, so Voice Control could not reach it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(region.shownName)
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
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

    // MARK: - Rows on the part

    /// The rows that read this stick or trigger: what each one is, what it
    /// sends and where it starts to count; a click shows it in the editor
    /// with its Options open, where the deadzone is set.
    private var partRowsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rows")
                .font(.subheadline)
                .accessibilityAddTraits(.isHeader)
            ForEach(partRows) { row in
                Button {
                    onJumpToRow?(row.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(row.number)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.output.isEmpty ? row.title : "\(row.title) \u{2192} \(row.output)")
                                .font(.callout)
                                .lineLimit(1)
                            if row.regionID == nil {
                                Text(String(localized: "Deadzone \(Int((row.deadzone * 100).rounded()))%"))
                                    .font(.caption)
                                    .foregroundStyle(Color.red.opacity(0.85))
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onJumpToRow == nil)
                .help("Show this row in the editor")
            }
        }
    }

    /// The deadzones of the direction rows here, each once.
    private var rowDeadzones: [Double] {
        Array(Set(partRows.filter { $0.regionID == nil }.map { ($0.deadzone * 100).rounded() / 100 })).sorted()
    }

    /// Where the first of those rows counts as pushed all the way.
    private var rowFullPush: Double {
        partRows.filter { $0.regionID == nil }.map(\.fullPush).min() ?? 1
    }

    // MARK: - Drawing

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            // On a selected region's handle a drag reshapes it, inside a
            // region it moves it, on empty travel it draws a new one.
            .onChanged { value in
                let mode = dragMode ?? StickRegionDrag.mode(at: value.startLocation, size: size,
                                                           regions: svc.regions(forStick: regionKey),
                                                           selected: selectedRegionID, bands: showsBands)
                dragMode = mode
                if mode != .draw {
                    if let changed = mode.apply(from: value.startLocation, to: value.location, size: size),
                       let found = svc.region(with: changed.id) {
                        svc.upsert(changed, stickIndex: found.stickIndex)
                        selectedRegionID = changed.id
                    }
                    return
                }
                guard svc.regions(forStick: regionKey).count < Self.maxRegions else { return }
                drawingNewRegion = true
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                defer { dragMode = nil }
                if let mode = dragMode, mode != .draw { return }
                guard drawingNewRegion, let start = dragStart else { return }
                let end = value.location
                defer { drawingNewRegion = false; dragStart = nil; dragCurrent = nil }
                if showsBands {
                    let from = 1 - max(0, min(1, Double(max(start.y, end.y) / size.height)))
                    let to = 1 - max(0, min(1, Double(min(start.y, end.y) / size.height)))
                    // The bottom edge snaps to rest only when drawn right at
                    // it: a band starting a little above it stays clear of
                    // a released trigger.
                    let low = from <= 0.01 ? 0 : (from * 100).rounded() / 100
                    if to - from > 0.03 { addBand(from: low, to: Self.snapEdge(to)) }
                    return
                }
                if newShape == .ring {
                    let ring = ringFrom(start, end, size: size)
                    if ring.outer - ring.inner > 0.04 { addRing(ring) }
                    return
                }
                let normMinX = max(0, min(1, Double(min(start.x, end.x) / size.width)))
                let normMaxX = max(0, min(1, Double(max(start.x, end.x) / size.width)))
                let normMinY = max(0, min(1, Double(min(start.y, end.y) / size.height)))
                let normMaxY = max(0, min(1, Double(max(start.y, end.y) / size.height)))
                if (normMaxX - normMinX) > 0.04 && (normMaxY - normMinY) > 0.04 {
                    addRegion(minX: normMinX, maxX: normMaxX,
                              minY: normMinY, maxY: normMaxY)
                }
            }
    }

    /// The ring a drag draws: its two ends set the two distances and the
    /// two directions, taking the shorter way around. A drag straight out
    /// from the center (almost no turn) makes a whole ring.
    private func ringFrom(_ a: CGPoint, _ b: CGPoint, size: CGSize) -> RingSector {
        func polar(_ p: CGPoint) -> (r: Double, deg: Double) {
            let x = Double(p.x / max(1, size.width)) * 2 - 1
            let y = Double(p.y / max(1, size.height)) * 2 - 1
            return (min(1, hypot(x, y)), RingSector.wrap(atan2(-y, x) * 180 / .pi))
        }
        let pa = polar(a), pb = polar(b)
        var start = pa.deg.rounded(), end = pb.deg.rounded()
        if RingSector.wrap(end - start) > 180 { swap(&start, &end) }
        if RingSector.wrap(end - start) < 6 { start = 0; end = 0 }
        return RingSector(inner: Self.snapEdge(min(pa.r, pb.r)),
                          outer: Self.snapEdge(max(pa.r, pb.r)),
                          start: start, end: end).clamped()
    }

    /// Within a few percent of the center or of full travel counts as there:
    /// a drag rarely lands exactly on either.
    static func snapEdge(_ v: Double) -> Double {
        let r = (v * 100).rounded() / 100
        return r <= 0.03 ? 0 : (r >= 0.97 ? 1 : r)
    }

    private func nextName() -> (name: String, colorIndex: Int) {
        let count = svc.regions(forStick: regionKey).count
        return (String(localized: "Region \(count + 1)").withoutRTLMark, count % TouchpadRegion.colorPalette.count)
    }

    private func addRing(_ ring: RingSector) {
        let n = nextName()
        let region = TouchpadRegion.ring(name: n.name, ring, colorIndex: n.colorIndex)
        svc.upsert(region, stickIndex: regionKey)
        selectedRegionID = region.id
    }

    private func addBand(from: Double, to: Double) {
        let n = nextName()
        let region = TouchpadRegion.band(name: n.name, from: from, to: to, colorIndex: n.colorIndex)
        svc.upsert(region, stickIndex: regionKey)
        selectedRegionID = region.id
    }

    private func addRegion(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let n = nextName()
        let region = TouchpadRegion(name: n.name, minX: minX, maxX: maxX,
                                     minY: minY, maxY: maxY, colorIndex: n.colorIndex)
        svc.upsert(region, stickIndex: regionKey)
        selectedRegionID = region.id
    }

    private func deleteRegion(_ id: UUID) {
        if selectedRegionID == id { selectedRegionID = nil }
        svc.delete(id)
    }

    private func commitRename(for id: UUID) {
        let trimmed = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let lookup = svc.region(with: id), trimmed != lookup.region.shownName {
            var copy = lookup.region
            copy.name = trimmed
            svc.upsert(copy, stickIndex: lookup.stickIndex)
        }
        renamingRegionID = nil
        renamingText = ""
    }

    // MARK: - Live polling

    private func startPolling() {
        pollTimer?.invalidate()
        // 60 Hz, as the Adjust live sheet samples, so the dot and the fill move as smoothly.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                refreshLiveStick()
            }
        }
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshLiveStick() {
        // The engine's reading of the first controller, so a pad the app
        // reads itself (not through Game Controller) shows here too, with
        // the rest the engine removes already removed.
        guard let state = controllerService.peekControllerState(at: slot), !state.axes.isEmpty else {
            liveStickActive = false
            return
        }
        if showsBands {
            guard let v = state.axes[bandAxis] else { liveStickActive = false; return }
            let oneWay = StickRegionService.axisIsOneWay(bandAxis)
                || controllerService.axisReadsOneWay(slot: slot, index: bandAxis)
            liveFraction = StickRegionService.travelFraction(axis: bandAxis, value: v, oneWay: oneWay)
            liveStickActive = true
            return
        }
        // The app reads stick Y with down positive, the canvas's own way.
        let fx = state.axes[selectedStick * 2] ?? 0, fy = state.axes[selectedStick * 2 + 1] ?? 0
        let x = Double(fx), y = Double(fy)
        liveStickPosition = CGPoint(x: (x + 1.0) / 2.0, y: (y + 1.0) / 2.0)
        liveX = fx; liveY = fy
        liveStickActive = true
        // The trail the sheet keeps: only past half the smallest deadzone, so
        // the resting stick does not pile dots in the middle.
        if hypot(fx, fy) > Float(rowDeadzones.first ?? 0.25) * 0.5 {
            trail.append((x: fx, y: fy))
            if trail.count > 200 { trail.removeFirst(trail.count - 200) }
        }
    }

    // MARK: - Accessibility helpers

    /// Human-readable extent of a region in the canvas coordinate space,
    /// phrased for VoiceOver (e.g. "left 20 percent to 60 percent, up 10
    /// percent to 50 percent"). Canvas X runs left to right, canvas Y runs
    /// top (up) to bottom (down).
    private func regionExtentDescription(_ region: TouchpadRegion) -> String {
        let pct: (Double) -> Int = { Int(($0 * 100).rounded()) }
        if let ring = region.ring {
            if ring.span >= 360 {
                return String(localized: "Whole ring from \(pct(ring.inner)) to \(pct(ring.outer)) percent of the way out.")
            }
            return String(localized: "Ring from \(pct(ring.inner)) to \(pct(ring.outer)) percent of the way out, from \(Int(ring.start.rounded())) to \(Int((ring.start + ring.span).rounded()) % 360) degrees, where 0 is right and 90 is up.")
        }
        return String(localized: "Horizontal \(pct(region.minX)) to \(pct(region.maxX)) percent, vertical \(pct(region.minY)) to \(pct(region.maxY)) percent, where 0 is left and top.")
    }

    /// Value spoken for the whole canvas: how many regions it holds, plus
    /// which named region the live stick currently occupies (if any).
    private var panelAccessibilityValue: String {
        let regions = svc.regions(forStick: regionKey)
        var parts: [String] = []
        if regions.isEmpty {
            parts.append(String(localized: "No regions defined"))
        } else {
            parts.append(regions.count == 1 ? String(localized: "1 region defined") : String(localized: "\(regions.count) regions defined"))
        }
        parts.append(stickAccessibilityValue)
        return parts.joined(separator: ". ")
    }

    /// Value describing the live stick: no controller, at center, or the
    /// name of the region it is currently inside.
    private var stickAccessibilityValue: String {
        guard liveStickActive else { return String(localized: "No controller connected") }
        if let occupied = occupiedRegion {
            return String(localized: "Stick in region \(occupied.shownName)")
        }
        let dx = liveStickPosition.x - 0.5
        let dy = liveStickPosition.y - 0.5
        if abs(dx) < 0.03 && abs(dy) < 0.03 {
            return String(localized: "Stick centered")
        }
        return String(localized: "Stick outside all regions")
    }

    /// The region the live stick position currently falls inside, if any.
    /// Uses the same 0...1 canvas convention as `liveStickPosition`.
    private var occupiedRegion: TouchpadRegion? {
        guard liveStickActive else { return nil }
        if showsBands {
            return svc.regions(forStick: regionKey).first { $0.containsTravel(liveFraction) }
        }
        // The same test the engine makes, so a ring and a shared edge read
        // here as they fire.
        let x = liveStickPosition.x
        let y = liveStickPosition.y
        return svc.regions(forStick: regionKey).first { $0.contains(normalizedX: x, y: y) }
    }

    /// Non-drag region creation for keyboard and switch users. Adds a
    /// default region centered on the canvas which can then be renamed
    /// or removed from the regions list.
    private func addCenteredRegion() {
        guard svc.regions(forStick: regionKey).count < Self.maxRegions else { return }
        if showsBands { addBand(from: 0.35, to: 0.65) }
        else if newShape == .ring { addRing(RingSector(inner: 0.5, outer: 1, start: 45, end: 135)) }
        else { addRegion(minX: 0.35, maxX: 0.65, minY: 0.35, maxY: 0.65) }
    }

    /// The axis picker's line: its name, and how many bands it has.
    private func bandAxisMenuName(_ axis: Int) -> String {
        let name = StickRegionService.axisDisplayName(axis)
        let n = svc.regions(forStick: StickRegionService.bandKeyBase + axis).count
        return n == 0 ? name : "\(name) (\(n))"
    }

    // MARK: - Band bar

    /// Names for the two ends of the bar: what the low and high end of
    /// the travel mean for this axis.
    private var bandEnds: (low: String, high: String) {
        StickRegionService.travelEnds(axis: bandAxis)
    }

    /// One axis's travel, drawn exactly as the Adjust live sheet draws a
    /// trigger: the bar fills with the pull, the low end at the bottom.
    private var bandPanel: some View {
        let h = gaugeHeight, w: CGFloat = 90
        let regions = svc.regions(forStick: regionKey)
        let inside = occupiedRegion?.id
        let trigger = bandAxis == 4 || bandAxis == 5
        let pct = DeadzoneCalibrationView.percent
        var labels: [(color: Color, text: String)] = [
            (.secondary, trigger ? String(localized: "\(pct(1)) Top", comment: "The top of the deadzone bar, 100%")
                                 : "\(pct(1)) \(bandEnds.high)")]
        if rowFullPush < 0.99 { labels.append((.green, String(localized: "Full push at \(pct(rowFullPush))"))) }
        if let dz = rowDeadzones.first { labels.append((.red, String(localized: "Deadzone \(pct(dz))"))) }
        labels.append((.accentColor, String(localized: "Current \(pct(liveAmount))")))
        labels.append((.secondary, trigger ? String(localized: "\(pct(0)) Rest", comment: "The bottom of the deadzone bar, 0%, the stick at rest")
                                           : "\(pct(0)) \(bandEnds.low)"))
        return TriggerGauge(width: w, height: h, pulled: liveAmount, deadzones: rowDeadzones, fullPush: rowFullPush,
                            bands: regions, lit: { $0.id == inside }, selected: selectedRegionID, labels: labels) {
            drawingLayer(size: CGSize(width: w, height: h), regions: regions)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Travel bar for \(StickRegionService.axisDisplayName(bandAxis))")
        .accessibilityValue(panelAccessibilityValue)
        .accessibilityHint("The low end of the travel is at the bottom. Contains the bands and a line at the axis's live reading.")
        .accessibilityAction(named: Text("Add region in the center")) { addCenteredRegion() }
        .accessibilityAction(named: Text("Delete selected region")) {
            if let id = selectedRegionID { pendingDeleteRegionID = id }
        }
    }

    private func bandExtentDescription(_ region: TouchpadRegion) -> String {
        let pct: (Double) -> Int = { Int(($0 * 100).rounded()) }
        return String(localized: "From \(pct(region.minY)) to \(pct(region.maxY)) percent of the travel, where 0 is \(bandEnds.low).")
    }

    // MARK: - Helpers

    private func paletteColor(at index: Int) -> Color {
        let palette = TouchpadRegion.colorPalette
        let name = palette[((index % palette.count) + palette.count) % palette.count]
        switch name {
        case "mint": return .mint
        case "cyan": return .cyan
        case "pink": return .pink
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "indigo": return .indigo
        case "green": return .green
        default: return .gray
        }
    }
}

// MARK: - Shared zone drawing

extension TouchpadRegion {
    /// The box a zone is drawn in, 0...1 on the stick's plane: a ring's own
    /// bounding box, so the drawing matches the zone that fires.
    var drawnBox: CGRect {
        ring?.boundingBox ?? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A ring zone drawn in its bounding box: the frame it is given is that
/// box, so it lays out like a rectangle zone.
struct RingSectorShape: Shape {
    let ring: RingSector

    func path(in rect: CGRect) -> Path {
        let box = ring.boundingBox
        guard box.width > 0.0001, box.height > 0.0001 else { return Path() }
        let sx = rect.width / box.width, sy = rect.height / box.height
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + (p.x - box.minX) * sx, y: rect.minY + (p.y - box.minY) * sy)
        }
        let n = max(8, Int(ring.span / 4))
        func arc(_ r: Double, reversed: Bool) -> [CGPoint] {
            let steps = Array(0...n)
            return (reversed ? steps.reversed() : steps).map {
                map(RingSector.point(r: r, degrees: ring.start + ring.span * Double($0) / Double(n)))
            }
        }
        var path = Path()
        path.addLines(arc(ring.outer, reversed: false))
        if ring.span >= 360 {
            path.closeSubpath()
            if ring.inner > 0.001 {
                path.addLines(arc(ring.inner, reversed: true))
                path.closeSubpath()
            }
        } else {
            if ring.inner > 0.001 {
                for p in arc(ring.inner, reversed: true) { path.addLine(to: p) }
            } else {
                path.addLine(to: map(CGPoint(x: 0.5, y: 0.5)))
            }
            path.closeSubpath()
        }
        return path
    }
}

/// Where a zone takes clicks: the ring itself, or the whole rectangle.
struct ZoneHitShape: Shape {
    let ring: RingSector?
    func path(in rect: CGRect) -> Path {
        if let ring { return RingSectorShape(ring: ring).path(in: rect) }
        return Path(roundedRect: rect, cornerRadius: 4)
    }
}

/// A zone's colored shape: a rounded rectangle, or the ring.
struct ZoneSwatch: View {
    let ring: RingSector?
    let color: Color
    let fill: Double
    let stroke: Double
    let lineWidth: CGFloat

    var body: some View {
        if let ring {
            RingSectorShape(ring: ring)
                .fill(color.opacity(fill), style: FillStyle(eoFill: true))
                .overlay(RingSectorShape(ring: ring).stroke(color.opacity(stroke), lineWidth: lineWidth))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(fill))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(stroke), lineWidth: lineWidth))
        }
    }
}

/// Typed distances and directions for a ring zone, the way to place one
/// without dragging.
struct RingBoundsFields: View {
    @Environment(\.appTextScale) private var textScale
    let region: TouchpadRegion
    let save: (TouchpadRegion) -> Void

    private var ring: RingSector { region.ring ?? RingSector(inner: 0, outer: 1, start: 0, end: 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Distance in percent, direction in degrees")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                // Each keystroke saves, so a distance typed past the other
                // edge stops short of it rather than swapping the two: the
                // 1 of 100 would otherwise become the new inner edge.
                field(String(localized: "Inner"), value: Int((ring.inner * 100).rounded())) {
                    var r = ring; r.inner = min(Double($0) / 100, r.outer - 0.02); set(r)
                }
                field(String(localized: "Outer"), value: Int((ring.outer * 100).rounded())) {
                    var r = ring; r.outer = max(Double($0) / 100, r.inner + 0.02); set(r)
                }
                field(String(localized: "From"), value: Int(ring.start.rounded())) { var r = ring; r.start = Double($0); set(r) }
                field(String(localized: "To"), value: Int((ring.start + ring.span).rounded()) % 360) { var r = ring; r.end = Double($0); set(r) }
            }
            Text("0 degrees is right and 90 is up; the ring runs counterclockwise from From to To. The same From and To make a whole ring.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, value: Int, apply: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, value: SwiftUI.Binding(get: { value }, set: { apply($0) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(minWidth: 52 * max(1, textScale))
                .accessibilityLabel("\(label) of \(region.shownName)")
        }
    }

    private func set(_ r: RingSector) {
        var updated = region
        let ring = r.clamped()
        updated.ring = ring
        let box = ring.boundingBox
        updated.minX = box.minX; updated.maxX = box.maxX
        updated.minY = box.minY; updated.maxY = box.maxY
        save(updated)
    }
}

/// Typed range for a band on one axis's travel.
struct BandBoundsFields: View {
    @Environment(\.appTextScale) private var textScale
    let region: TouchpadRegion
    let save: (TouchpadRegion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Range of the travel, in percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                field(String(localized: "From"), value: region.minY) { set(from: $0) }
                field(String(localized: "To"), value: region.maxY) { set(to: $0) }
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
                .frame(minWidth: 52 * max(1, textScale))
                .accessibilityLabel("\(label) of \(region.shownName), percent")
        }
    }

    /// Each keystroke saves, so an end typed past the other stops short of
    /// it rather than swapping the two (typing 100 into To passes through 1).
    private func set(from: Double? = nil, to: Double? = nil) {
        var r = region
        var lo = r.minY, hi = r.maxY
        if let from { lo = max(0, min(from, hi - 0.02)) }
        if let to { hi = min(1, max(to, lo + 0.02)) }
        r.minY = lo; r.maxY = hi
        r.minX = 0; r.maxX = 0
        save(r)
    }
}

// MARK: - Recording a stick gesture

/// Watches a stick and writes down each flick as it is made, so a gesture
/// can be set by doing it. A flick is out past the reach and back to the
/// middle; its direction is the nearest of the eight to its farthest point.
struct StickGestureRecorder: View {
    let stick: Int
    let slot: Int
    let reach: Double
    /// The row's own timing and Invert, so what is recorded is what fires.
    var longestFlickMs: Int = 400
    var windowMs: Int = 600
    var inverted: Bool = false
    let onSave: ([GestureStep]) -> Void

    @EnvironmentObject private var controllerService: GameControllerService
    @Environment(\.dismiss) private var dismiss

    @State private var steps: [GestureStep] = []
    @State private var point = CGPoint(x: 0.5, y: 0.5)
    @State private var hasPad = false
    @State private var out = false
    @State private var outStart: Double = 0
    @State private var peak = (x: 0.0, y: 0.0, m: 0.0)
    @State private var lastFlickAt: Double = 0
    @State private var finished = false
    @State private var note: String?
    @State private var timer: Timer?

    /// Recording ends once the row's time between flicks has passed.
    private var quietEnd: Double { max(0.6, Double(windowMs) / 1000) }
    /// A push held out longer than the row allows is not a flick (0: any).
    private var longestFlick: Double { longestFlickMs > 0 ? Double(longestFlickMs) / 1000 : .infinity }

    private var restRadius: Double { min(0.35, reach * 0.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record a stick gesture")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(stick == 1
                 ? String(localized: "Flick the right stick out and let it come back to the middle, once for each flick. Recording stops shortly after the last flick.")
                 : String(localized: "Flick the left stick out and let it come back to the middle, once for each flick. Recording stops shortly after the last flick."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 18) {
                stickPicture
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Flicks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Text(steps.isEmpty ? String(localized: "None yet") : steps.compactMap { $0.direction?.arrow }.joined(separator: "  "))
                        .font(.system(size: 28, weight: .semibold))
                        .accessibilityLabel(GestureStep.describe(steps))
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Start Over") { startOver() }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(steps.isEmpty && !finished)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.solidSecondaryCompact)
                    .keyboardShortcut(.cancelAction)
                Button("Use This Gesture") { onSave(steps); dismiss() }
                    .buttonStyle(.solidCompact)
                    .keyboardShortcut(.defaultAction)
                    .disabled(steps.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Holds the running preset's outputs back while it listens, as Scan
        // does, so the flicks being recorded do not also fire the stick's rows.
        .onAppear { MappingEngine.editorListenerArmed = true; start() }
        .onDisappear { MappingEngine.editorListenerArmed = false; timer?.invalidate(); timer = nil }
    }

    private var status: String {
        if !hasPad { return String(localized: "No controller is reading. Connect one to record.") }
        if finished { return String(localized: "Done. Use this gesture, or start over.") }
        if steps.isEmpty { return String(localized: "Waiting for the first flick.") }
        return String(localized: "Recording. Flick again, or wait to finish.")
    }

    /// The stick's travel, the reach as a ring, and the live point.
    private var stickPicture: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Circle().fill(Color.black.opacity(0.25))
                Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                Circle()
                    .stroke(Color.mint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: w * reach, height: w * reach)
                Circle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: w * restRadius, height: w * restRadius)
                Circle()
                    .fill(out ? Color.mint : Color.accentColor)
                    .frame(width: 12, height: 12)
                    .position(x: point.x * w, y: point.y * w)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stick")
        .accessibilityValue(out ? String(localized: "Pushed out") : String(localized: "In the middle"))
    }

    private func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startOver() {
        steps = []; finished = false; out = false; note = nil
    }

    private func tick() {
        guard let state = controllerService.peekControllerState(at: slot), !state.axes.isEmpty else {
            hasPad = false; return
        }
        hasPad = true
        var x = Double(state.axes[stick == 1 ? 2 : 0] ?? 0)
        var y = Double(state.axes[stick == 1 ? 3 : 1] ?? 0)
        guard x.isFinite, y.isFinite else { return }
        if inverted { x = -x; y = -y }
        point = CGPoint(x: (max(-1, min(1, x)) + 1) / 2, y: (max(-1, min(1, y)) + 1) / 2)
        let now = CACurrentMediaTime()
        if !steps.isEmpty, !out, !finished, now - lastFlickAt > quietEnd {
            finished = true
            AccessibilityNotification.Announcement(steps.count == 1
                ? String(localized: "Recorded 1 flick: \(GestureStep.describe(steps))")
                : String(localized: "Recorded \(steps.count) flicks: \(GestureStep.describe(steps))")).post()
        }
        guard !finished, steps.count < GestureStep.maxSteps else { return }
        let m = hypot(x, y)
        if !out {
            if m >= reach { out = true; outStart = now; peak = (x, y, m) }
            return
        }
        if m > peak.m { peak = (x, y, m) }
        guard m <= restRadius else { return }
        out = false
        if now - outStart > longestFlick {
            note = String(localized: "That push was held out too long to count as a flick.")
            AccessibilityNotification.Announcement(note ?? "").post()
            return
        }
        note = nil
        let direction = Self.nearest(x: peak.x, y: peak.y)
        steps.append(GestureStep(direction: direction))
        AccessibilityNotification.Announcement(direction.displayName).post()
        lastFlickAt = now
        if steps.count >= GestureStep.maxSteps { finished = true }
    }

    /// The nearest of the eight directions to a point.
    static func nearest(x: Double, y: Double) -> StickDirection {
        let angle = RingSector.wrap(atan2(-y, x) * 180 / .pi)
        let order: [StickDirection] = [.right, .upRight, .up, .upLeft, .left, .downLeft, .down, .downRight]
        return order[Int(RingSector.wrap(angle + 22.5) / 45) % 8]
    }
}

// MARK: - Zones in the editor

/// A part of a device that zones are drawn on. The editor's Zones section
/// shows one at a time, inside the device's group, and every "edit zones"
/// button in the app opens it there rather than in a sheet of its own.
enum ZonePart: Hashable, Identifiable {
    /// The main touchpad: a PlayStation pad's, or a Steam Controller's right trackpad.
    case touchpad
    /// A Steam Controller's left trackpad, with regions of its own.
    case leftTrackpad
    case screen
    /// A stick: 0 left, 1 right.
    case stick(Int)
    /// One axis's travel, by the axis (4 and 5 are the triggers).
    case band(Int)

    var id: String {
        switch self {
        case .touchpad: return "touchpad"
        case .leftTrackpad: return "left-trackpad"
        case .screen: return "screen"
        case .stick(let s): return "stick-\(s)"
        case .band(let a): return "band-\(a)"
        }
    }

    /// From a stick zone key: a stick (0, 1) or 100 plus an axis.
    init(regionKey key: Int) {
        self = StickRegionService.isBandKey(key) ? .band(key - StickRegionService.bandKeyBase) : .stick(key == 1 ? 1 : 0)
    }

    var title: String {
        switch self {
        case .touchpad: return String(localized: "Touchpad")
        case .leftTrackpad: return String(localized: "Left trackpad")
        case .screen: return String(localized: "Screen")
        case .stick(let s): return s == 1 ? String(localized: "Right stick") : String(localized: "Left stick")
        case .band(let a): return StickRegionService.axisDisplayName(a)
        }
    }
}

/// Asks the open editor to show a part's zones in one device group: the
/// group a row belongs to, or the group at an index.
struct ShowZonesRequest {
    var groupIndex: Int? = nil
    var bindingID: UUID? = nil
    let part: ZonePart

    static let name = Notification.Name("InputConfig.ShowZones")

    func post() { NotificationCenter.default.post(name: Self.name, object: self) }
}

/// A row that reads a stick or trigger, as its region editor lists it.
struct RegionPartRow: Identifiable {
    let id: UUID
    let number: Int
    /// The region's name, or the axis and direction ("Left trigger +").
    let title: String
    /// Its note, or what it sends.
    let output: String
    let regionID: UUID?
    /// Where it starts to count, 0 to 1.
    let deadzone: Double
    /// Where it counts as pushed all the way.
    var fullPush: Double = 1
}

// MARK: - Moving and resizing rings and bands

/// What a drag on the stick or the trigger bar does, decided where it
/// starts: on a handle of the selected region it reshapes it, inside a
/// region it moves it, and on empty travel it draws a new one.
enum StickRegionDrag: Equatable {
    case draw
    /// A ring: turned around the center and slid in or out together.
    case moveRing(TouchpadRegion)
    /// One edge of a ring: 0 inner, 1 outer, 2 start direction, 3 end direction.
    case ringEdge(TouchpadRegion, edge: Int)
    case moveBand(TouchpadRegion)
    /// A band's low (0) or high (1) end.
    case bandEnd(TouchpadRegion, end: Int)
    /// A rectangle drawn before rings, as a touchpad's.
    case rect(RectRegionDrag)

    static let reach: CGFloat = 9

    /// The ring's handles in the drawing's points: the middle of the inner
    /// and outer edges, then the middle of each side. A whole ring has
    /// only the two at the top.
    static func ringHandles(_ ring: RingSector, size: CGSize) -> [CGPoint] {
        let mid = ring.span >= 360 ? 90 : ring.start + ring.span / 2
        let midR = (ring.inner + ring.outer) / 2
        func pt(_ r: Double, _ deg: Double) -> CGPoint {
            let p = RingSector.point(r: r, degrees: deg)
            return CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        var out = [pt(ring.inner, mid), pt(ring.outer, mid)]
        if ring.span < 360 { out += [pt(midR, ring.start), pt(midR, ring.start + ring.span)] }
        return out
    }

    static func mode(at p: CGPoint, size: CGSize, regions: [TouchpadRegion], selected: UUID?, bands: Bool) -> StickRegionDrag {
        guard size.width > 0, size.height > 0 else { return .draw }
        let picked = selected.flatMap { id in regions.first { $0.id == id } }
        if bands {
            let f = 1 - Double(p.y / size.height)
            if let r = picked {
                if abs(CGFloat((1 - r.minY)) * size.height - p.y) <= reach { return .bandEnd(r, end: 0) }
                if abs(CGFloat((1 - r.maxY)) * size.height - p.y) <= reach { return .bandEnd(r, end: 1) }
            }
            if let hit = regions.last(where: { $0.containsTravel(f) }) { return .moveBand(hit) }
            return .draw
        }
        if let r = picked, let ring = r.ring {
            for (i, h) in ringHandles(ring, size: size).enumerated() where hypot(h.x - p.x, h.y - p.y) <= reach {
                return .ringEdge(r, edge: i)
            }
        }
        let x = Double(p.x / size.width), y = Double(p.y / size.height)
        if let hit = regions.last(where: { $0.contains(normalizedX: x, y: y) }) {
            return hit.ring != nil ? .moveRing(hit)
                : .rect(RectRegionDrag.mode(at: p, size: size, regions: [hit], selected: selected))
        }
        if let r = picked, r.ring == nil {
            let m = RectRegionDrag.mode(at: p, size: size, regions: [r], selected: r.id)
            if m != .draw { return .rect(m) }
        }
        return .draw
    }

    private static func polar(_ p: CGPoint, _ size: CGSize) -> (r: Double, deg: Double) {
        let x = Double(p.x / max(1, size.width)) * 2 - 1
        let y = Double(p.y / max(1, size.height)) * 2 - 1
        return (min(1, hypot(x, y)), RingSector.wrap(atan2(-y, x) * 180 / .pi))
    }

    private static func reshaped(_ r: TouchpadRegion, _ ring: RingSector) -> TouchpadRegion {
        // Changed in place, so what a newer build wrote on it stays.
        var out = r
        let box = ring.boundingBox
        out.minX = box.minX; out.maxX = box.maxX
        out.minY = box.minY; out.maxY = box.maxY
        out.ring = ring
        return out
    }

    /// The region as the drag leaves it.
    func apply(from start: CGPoint, to current: CGPoint, size: CGSize) -> TouchpadRegion? {
        let gap = 0.05
        switch self {
        case .draw:
            return nil
        case .rect(let m):
            return m.apply(from: start, to: current, size: size)
        case .moveRing(let r):
            guard var ring = r.ring else { return nil }
            let a = Self.polar(start, size), b = Self.polar(current, size)
            var turn = b.deg - a.deg
            if turn > 180 { turn -= 360 } else if turn < -180 { turn += 360 }
            if ring.span < 360 {
                ring.start = RingSector.wrap((ring.start + turn).rounded())
                ring.end = RingSector.wrap((ring.end + turn).rounded())
            }
            let width = ring.outer - ring.inner
            let inner = min(max(0, ring.inner + (b.r - a.r)), 1 - width)
            ring.inner = (inner * 100).rounded() / 100
            ring.outer = min(1, ring.inner + width)
            return Self.reshaped(r, ring)
        case .ringEdge(let r, let edge):
            guard var ring = r.ring else { return nil }
            let b = Self.polar(current, size)
            let span = ring.span
            switch edge {
            case 0: ring.inner = StickRegionsView.snapEdge(min(b.r, ring.outer - gap))
            case 1: ring.outer = StickRegionsView.snapEdge(max(b.r, ring.inner + gap))
            case 2:
                // The start moves, the end stays: never past it. Carried
                // past the end the span reads nearly whole, so it stops 6
                // degrees short instead of turning inside out.
                let newStart = b.deg.rounded()
                let newSpan = RingSector.wrap(ring.end - newStart)
                ring.start = newSpan < 6 || (newSpan > 330 && span <= 330)
                    ? RingSector.wrap(ring.end - 6) : newStart
            default:
                let newEnd = b.deg.rounded()
                let newSpan = RingSector.wrap(newEnd - ring.start)
                ring.end = newSpan < 6 || (newSpan > 330 && span <= 330)
                    ? RingSector.wrap(ring.start + 6) : newEnd
            }
            return Self.reshaped(r, ring.clamped())
        case .moveBand(var r):
            let d = -Double((current.y - start.y) / max(1, size.height))
            let h = r.maxY - r.minY
            let low = min(max(0, r.minY + d), 1 - h)
            r.minY = (low * 100).rounded() / 100
            r.maxY = min(1, r.minY + h)
            return r
        case .bandEnd(var r, let end):
            let f = max(0, min(1, 1 - Double(current.y / max(1, size.height))))
            let v = (f * 100).rounded() / 100
            if end == 0 { r.minY = min(v, r.maxY - 0.03) } else { r.maxY = max(v, r.minY + 0.03) }
            return r
        }
    }
}

/// Dots on the selected ring or band: where a drag reshapes it.
struct StickRegionHandles: View {
    let points: [CGPoint]
    let color: Color

    var body: some View {
        ForEach(Array(points.enumerated()), id: \.offset) { _, p in
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(color, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .position(p)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The one line every region editor shows on how to use it, and the line
/// after it on what a region is for, worded for the thing drawn.
enum RegionEditorHint {
    static var text: String {
        String(localized: "Drag on empty space to draw a region, drag a region to move it, and drag its dots to resize it. Right-click a region to rename, duplicate or delete it.")
    }

    enum Kind { case trigger, stick, touchpad, screen }

    static func purpose(_ kind: Kind) -> String {
        switch kind {
        case .trigger:
            return String(localized: "Then give each region its own action in its row: a light pull can aim while a full pull fires, so one trigger does two jobs.")
        case .stick:
            return String(localized: "Then give each region its own action in its row: a small push can walk while the edge sprints, or each direction can send its own key.")
        case .touchpad:
            return String(localized: "Then give each region its own action in its row: a tap or a press in a corner can do something different from the middle.")
        case .screen:
            return String(localized: "Then give each region its own action in its row: the pointer reaching a corner of the screen can run a shortcut or switch apps.")
        }
    }
}


#if DEBUG
/// Marketing capture hooks for the region editors (tools/post):
///   regiondraw "x0 y0 x1 y1"  show a drawing in progress, in fractions of
///                             the drawing; "" clears it
///   regioncursor "x y"        draw the arrow pointer there; "" clears it
///   regionselect "N"          select the Nth region, showing its dots
struct MarketingRegionHooks: ViewModifier {
    @Binding var draw: [Double]?
    @Binding var cursor: [Double]?
    let select: (Int) -> Void

    private func numbers(_ note: Notification) -> [Double] {
        ((note.object as? String) ?? "").split(separator: " ").compactMap { Double($0) }
    }

    func body(content: Content) -> some View {
        let dnc = DistributedNotificationCenter.default()
        return content
            .onReceive(dnc.publisher(for: .init("inputconfig.debug.regiondraw"))) { note in
                let v = numbers(note); draw = v.count == 4 ? v : nil
            }
            .onReceive(dnc.publisher(for: .init("inputconfig.debug.regioncursor"))) { note in
                let v = numbers(note); cursor = v.count == 2 ? v : nil
            }
            .onReceive(dnc.publisher(for: .init("inputconfig.debug.regionselect"))) { note in
                select(Int((note.object as? String) ?? "") ?? -1)
            }
    }
}

/// The system arrow pointer, its tip on the point. DEBUG only.
struct MarketingPointer: View {
    let at: CGPoint
    var body: some View {
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        return Image(nsImage: cursor.image)
            .frame(width: size.width, height: size.height)
            .position(x: at.x + size.width / 2 - cursor.hotSpot.x, y: at.y + size.height / 2 - cursor.hotSpot.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif
