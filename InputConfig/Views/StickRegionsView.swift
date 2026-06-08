import SwiftUI
import GameController

/// Lets the user define rectangular zones on a joystick stick's X/Y
/// plane. Mirrors the layout of `CursorRegionsView` and
/// `TouchpadCalibrationView`'s region editor but the canvas
/// represents the stick's deflection range (a square with a small
/// circular guide hinting at the physical stick's circular travel).
///
/// Coordinate convention: the canvas is 0...1 in both axes, mapped to
/// the stick's -1...1 axis values at the service layer. Y=0 is up.
struct StickRegionsView: View {
    @ObservedObject private var svc = StickRegionService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedStick: Int = 0  // 0 = left, 1 = right
    @State private var selectedRegionID: UUID?

    @State private var drawingNewRegion = false
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    @State private var renamingRegionID: UUID?
    @State private var renamingText: String = ""

    /// Live stick position, polled at 30 Hz so the binding-editor
    /// preview can show where the connected controller's stick is
    /// sitting right now. Only updates while at least one controller
    /// is connected; otherwise stays at (0.5, 0.5) i.e. center.
    @State private var liveStickPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var liveStickActive: Bool = false
    @State private var pollTimer: Timer?

    private static let maxRegions = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            mainContent
            footer
        }
        .padding(20)
        .frame(width: 760, height: 580)
        .onAppear(perform: startPolling)
        .onDisappear(perform: stopPolling)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stick Regions")
                .font(.title2.weight(.semibold))
            Text("Draw zones on a stick's X/Y plane. A binding fires while the stick is pushed into the zone. Good for binding diagonals as one input.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Stick", selection: $selectedStick) {
                    Text("Left Stick").tag(0)
                    Text("Right Stick").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Text(drawingNewRegion
                     ? "Click and drag on the stick preview to draw the new region."
                     : "Click Add Region, then drag on the stick preview to create one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                regionsPanel
                    .aspectRatio(1.0, contentMode: .fit)

                HStack {
                    Button {
                        drawingNewRegion = true
                        dragStart = nil
                        dragCurrent = nil
                    } label: {
                        Label("Add Region", systemImage: "plus.rectangle")
                    }
                    .disabled(drawingNewRegion
                              || (svc.regions(forStick: selectedStick).count >= Self.maxRegions))

                    if drawingNewRegion {
                        Button("Cancel") {
                            drawingNewRegion = false
                            dragStart = nil
                            dragCurrent = nil
                        }
                    }

                    Spacer()

                    Text(stickReadout)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)

                    Text("\(svc.regions(forStick: selectedStick).count) / \(Self.maxRegions) regions")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            regionsList
                .frame(width: 240)
        }
    }

    private var footer: some View {
        HStack {
            Text("Tip: bind to a stick region from the binding editor by setting input type to Stick Region.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Canvas

    private var regionsPanel: some View {
        GeometryReader { geo in
            ZStack {
                // Square backdrop with a circular travel guide ring -
                // hints at the physical stick's circular range without
                // hiding the rectangular coordinate space the regions
                // use.
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 10).stroke(Color.mint.opacity(0.6), lineWidth: 1.5)
                Circle()
                    .strokeBorder(Color.mint.opacity(0.25),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(8)

                // Center crosshair
                Path { p in
                    p.move(to: CGPoint(x: geo.size.width / 2, y: 4))
                    p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height - 4))
                    p.move(to: CGPoint(x: 4, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width - 4, y: geo.size.height / 2))
                }
                .stroke(Color.secondary.opacity(0.2),
                        style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                ForEach(svc.regions(forStick: selectedStick)) { region in
                    let isSelected = region.id == selectedRegionID
                    let rect = CGRect(
                        x: region.minX * geo.size.width,
                        y: region.minY * geo.size.height,
                        width: (region.maxX - region.minX) * geo.size.width,
                        height: (region.maxY - region.minY) * geo.size.height)
                    let color = paletteColor(at: region.colorIndex)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(isSelected ? 0.45 : 0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(color, lineWidth: isSelected ? 2 : 1)
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
                            if !drawingNewRegion {
                                selectedRegionID = region.id
                            }
                        }
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

                // Live stick position indicator - small filled dot
                // showing where the physical stick is right now. Lives
                // OFF the canvas surface (positioned absolutely, no
                // re-layout) so adding it doesn't pollute the editing
                // experience the way the early CursorRegions UI did.
                if liveStickActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .position(x: liveStickPosition.x * geo.size.width,
                                  y: liveStickPosition.y * geo.size.height)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(size: geo.size),
                     including: drawingNewRegion ? .gesture : .none)
        }
    }

    // MARK: - Region list

    private var regionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Defined Regions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if svc.regions(forStick: selectedStick).isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(svc.regions(forStick: selectedStick)) { region in
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
            } else {
                Text(region.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
            }
            Menu {
                Button("Rename") {
                    renamingRegionID = region.id
                    renamingText = region.name
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
        let count = svc.regions(forStick: selectedStick).count
        let name = "Region \(count + 1)"
        let colorIndex = count % TouchpadRegion.colorPalette.count
        let region = TouchpadRegion(name: name, minX: minX, maxX: maxX,
                                     minY: minY, maxY: maxY, colorIndex: colorIndex)
        svc.upsert(region, stickIndex: selectedStick)
        selectedRegionID = region.id
    }

    private func deleteRegion(_ id: UUID) {
        if selectedRegionID == id { selectedRegionID = nil }
        svc.delete(id)
    }

    private func commitRename(for id: UUID) {
        let trimmed = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let lookup = svc.region(with: id) {
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
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
        let controllers = GCController.controllers()
        guard let controller = controllers.first,
              let gamepad = controller.extendedGamepad else {
            liveStickActive = false
            return
        }
        let stick = selectedStick == 1 ? gamepad.rightThumbstick : gamepad.leftThumbstick
        let x = Double(stick.xAxis.value)
        let y = Double(stick.yAxis.value)
        // Map stick coords (-1...1) to canvas coords (0...1) with
        // Y inverted (positive stick Y = up; canvas Y = down).
        let cx = (x + 1.0) / 2.0
        let cy = (1.0 - (y + 1.0) / 2.0)
        liveStickPosition = CGPoint(x: cx, y: cy)
        liveStickActive = true
    }

    private var stickReadout: String {
        guard liveStickActive else { return "Stick: (no controller)" }
        return String(format: "Stick: %+.2f, %+.2f",
                      liveStickPosition.x * 2 - 1,
                      (1 - liveStickPosition.y) * 2 - 1)
    }

    // MARK: - Helpers

    private func paletteColor(at index: Int) -> Color {
        let palette = TouchpadRegion.colorPalette
        let name = palette[index % palette.count]
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
