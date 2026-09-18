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

    // MARK: - State

    /// The display the canvas represents and new regions belong to. Nil
    /// is "every display": the canvas then follows the pointer's display.
    @State private var chosenDisplay: DisplayKey?

    @State private var selectedRegionID: UUID?
    @State private var drawingNewRegion = false
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var renamingRegionID: UUID?
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            mainContent
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .onAppear { CursorRegionService.shared.beginTracking() }
        .onDisappear { CursorRegionService.shared.endTracking() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "rectangle.dashed")
                    .foregroundStyle(.tint)
                Text("Screen Regions")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.solidCompact)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Areas of a display. A binding fires while the pointer is inside one, whatever moves the pointer. A region belongs to every display or to one of them; zones on a controller's touchpad are a different input, in Touchpad Setup.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Main layout

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                displayRow

                regionsPanel
                    .aspectRatio(canvasAspectRatio, contentMode: .fit)

                HStack {
                    Button {
                        drawingNewRegion = true
                        dragStart = nil
                        dragCurrent = nil
                    } label: {
                        Label("Add region", systemImage: "plus.rectangle")
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .disabled(drawingNewRegion || regions.count >= Self.maxRegions)
                    .help(drawingNewRegion ? "Drag on the display preview to draw it" : "Draw a new region on the display shown")

                    if drawingNewRegion {
                        Button("Cancel") {
                            drawingNewRegion = false
                            dragStart = nil
                            dragCurrent = nil
                        }
                        .buttonStyle(.solidSecondaryCompact)
                    }

                    Spacer()

                    Text(cursorReadout)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)

                    Text("\(regions.count) / \(Self.maxRegions) regions")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            regionsList
                .frame(width: 240)
        }
    }

    /// Which display the canvas shows and new regions belong to.
    private var displayRow: some View {
        HStack(spacing: 10) {
            Text("Display")
                .font(.subheadline)
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
                Text(chosenDisplay.map { $0.name } ?? "Every display")
            }
            .fixedSize()
            .help("New regions belong to this display. Every display means the same area of whichever screen the pointer is on.")
            Text(displayHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var displayHint: String {
        if let d = chosenDisplay {
            return svc.isDisplayAttached(d) ? "regions here fire only on this display" : "not connected; shown at a guessed shape"
        }
        return svc.screenCount > 1 ? "the same area on any of \(svc.screenCount) displays" : "the same area on any display"
    }

    /// Every display any region refers to.
    private var storedDisplays: [DisplayKey] {
        var out: [DisplayKey] = []
        for r in regions { if let d = r.display, !out.contains(d) { out.append(d) } }
        return out
    }

    // MARK: - Canvas

    private var regionsPanel: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 10).stroke(Color.mint.opacity(0.6), lineWidth: 1.5)

                ForEach(regionsOnCanvas) { region in
                    let isPressed = svc.isRegionPressed(region.id)
                    let isSelected = region.id == selectedRegionID
                    let rect = CGRect(
                        x: region.minX * geo.size.width,
                        y: region.minY * geo.size.height,
                        width: (region.maxX - region.minX) * geo.size.width,
                        height: (region.maxY - region.minY) * geo.size.height)
                    let color = paletteColor(at: region.colorIndex)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(isPressed ? 0.65 : (isSelected ? 0.45 : 0.25)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(color, style: StrokeStyle(lineWidth: isSelected ? 2 : 1,
                                                                  dash: region.display == nil ? [] : [5, 3]))
                        )
                        .overlay(
                            Text(region.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(color.opacity(0.85))
                                .clipShape(Capsule()),
                            alignment: .topLeading
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .onTapGesture {
                            if !drawingNewRegion { selectedRegionID = region.id }
                        }
                        .help(region.display == nil ? "\(region.name): every display" : "\(region.name): \(region.display!.name) only")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Region \(region.name)")
                        .accessibilityValue(canvasRegionValue(region, isPressed: isPressed))
                        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                }

                // Live pointer dot, in the same normalised space the regions
                // hit-test against, only when the pointer is on this display.
                if pointerIsOnShownDisplay {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.mint, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .shadow(radius: 1)
                        .position(x: svc.cursorNormalized.x * geo.size.width,
                                  y: svc.cursorNormalized.y * geo.size.height)
                        .allowsHitTesting(false)
                }

                // Which display the canvas represents.
                Text(shownDisplay?.name ?? "Display")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.4)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                    .allowsHitTesting(false)

                // Live Force Touch pressure while pressing the Mac trackpad
                // over this window, bindable as Pressure and Deep Press on
                // the Mouse input type.
                HStack(spacing: 5) {
                    Image(systemName: "hand.tap.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    ProgressView(value: Double(min(max(externalInput.trackpadPressure, 0), 1)))
                        .frame(width: 64)
                    Text(externalInput.trackpadPressureStage >= 2
                         ? "Deep"
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
                                    ? "Deep press"
                                    : "\(Int(externalInput.trackpadPressure * 100)) percent")

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
                     including: drawingNewRegion ? .gesture : .none)
            .onReceive(cursorPollTimer) { _ in
                svc.pollCursorOnce()
                ExternalInputDeviceService.shared.ensurePressureMetricsMonitor()
            }
        }
    }

    // MARK: - Region list

    private var regionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Regions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if regions.isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
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
                .onExitCommand { cancelRename() }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(region.name)
                        .font(.body)
                        .lineLimit(1)
                    Text(displayTag(for: region))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                Button("Rename") {
                    renamingRegionID = region.id
                    renamingText = region.name
                }
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
                Button("Delete", role: .destructive) {
                    deleteRegion(region.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Region options for \(region.name)")
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
        .accessibilityLabel("Select region \(region.name), \(displayTag(for: region))")
        .accessibilityValue(isPressed ? "Active" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func displayTag(for region: TouchpadRegion) -> String {
        guard let d = region.display else { return "Every display" }
        return svc.isDisplayAttached(d) ? d.name : "\(d.name) (not connected)"
    }

    // MARK: - Drawing

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard drawingNewRegion else { return }
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
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
        let name = "Region \(count + 1)"
        let colorIndex = count % TouchpadRegion.colorPalette.count
        let region = TouchpadRegion(name: name, minX: minX, maxX: maxX,
                                     minY: minY, maxY: maxY, colorIndex: colorIndex,
                                     display: chosenDisplay)
        svc.upsert(region)
        selectedRegionID = region.id
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
        if !trimmed.isEmpty, var region = svc.region(with: id) {
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
        var value = "Positioned at \(x) percent across, \(y) percent down, \(w) by \(h) percent of the display, \(displayTag(for: region))"
        if isPressed { value += ", active" }
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

    private var cursorReadout: String {
        guard pointerIsOnShownDisplay else { return "Pointer on another display" }
        let p = svc.cursorNormalized
        return String(format: "Pointer: %.0f%%, %.0f%%", p.x * 100, p.y * 100)
    }

    private func paletteColor(at index: Int) -> Color {
        regionPaletteColor(at: index)
    }
}
