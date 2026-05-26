import SwiftUI

/// Touchpad setup sheet with two tabs:
///
/// * **Calibration** - the user drags their finger across the whole touchpad
///   until every cell is filled; the observed min/max X/Y are saved as the
///   normalization bounds in `TouchpadService`.
/// * **Regions** - the user defines named rectangles on the surface; any
///   binding of type `Touchpad Region` then fires while a finger is inside.
///
/// Both tabs share a live readout of finger positions from
/// `TouchpadService`, which the sheet keeps alive via `retain()` / `release()`.
struct TouchpadCalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case calibration
        case regions
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .calibration: return "Calibration"
            case .regions:     return "Regions"
            }
        }
    }

    @State private var selectedTab: Tab = .calibration

    // MARK: - Shared state

    /// Live finger 0 / 1 position in normalized 0..1 coordinates, refreshed
    /// at 30 Hz by the polling timer.
    @State private var liveFinger0: CGPoint?
    @State private var liveFinger1: CGPoint?
    @State private var pollTimer: Timer?

    private let surfaceWidth: Int
    private let surfaceHeight: Int

    // MARK: - Calibration tab state

    private let gridColumns = 12
    private let gridRows = 7

    @State private var touched: [Bool]
    @State private var minX: Int = .max
    @State private var maxX: Int = .min
    @State private var minY: Int = .max
    @State private var maxY: Int = .min
    /// True briefly after a successful save so the user sees a confirmation.
    @State private var showSavedConfirmation: Bool = false
    /// Triggers the unsaved-recording confirmation when the user tries to close.
    @State private var showUnsavedCloseDialog: Bool = false
    /// Cached snapshot of the saved calibration loaded on appear; we diff
    /// against the live min/max to decide if there's an unsaved recording.
    @State private var savedCalibrationOnOpen: TouchpadCalibration = .uncalibrated

    // MARK: - Regions tab state

    @State private var regions: [TouchpadRegion] = TouchpadService.shared.allRegions()
    @State private var selectedRegionID: UUID?
    /// Drag-to-draw state. While `dragStart` is non-nil we render a live
    /// preview rectangle that follows the cursor.
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    /// True while the user is in "click and drag to add a region" mode.
    @State private var drawingNewRegion = false
    @State private var renamingRegionID: UUID?
    @State private var renamingText: String = ""

    init() {
        let (w, h) = TouchpadService.shared.nominalSurfaceSize
        self.surfaceWidth = w
        self.surfaceHeight = h
        _touched = State(initialValue: Array(repeating: false, count: 12 * 7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Touchpad Setup")
                .font(.title2.weight(.semibold))

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch selectedTab {
            case .calibration:
                calibrationTab
            case .regions:
                regionsTab
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { attemptClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 720, height: 600)
        .onAppear {
            TouchpadService.shared.retain()
            startPolling()
            loadSavedCalibration()
        }
        .onDisappear {
            stopPolling()
            TouchpadService.shared.release()
        }
        .confirmationDialog(
            "You recorded a new calibration. Would you like to save it?",
            isPresented: $showUnsavedCloseDialog,
            titleVisibility: .visible
        ) {
            Button("Save Calibration") {
                saveCalibration()
                dismiss()
            }
            Button("Discard", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Your recorded X range \(minX) - \(maxX), Y range \(minY) - \(maxY) hasn't been saved yet. Closing will discard it unless you save first.")
        }
    }

    /// Close handler that asks for confirmation if there's an unsaved
    /// recording (live bounds differ from what's persisted in TouchpadService).
    private func attemptClose() {
        if hasUnsavedRecording {
            showUnsavedCloseDialog = true
        } else {
            dismiss()
        }
    }

    /// True when the live bounds differ from the saved calibration. Used by
    /// the Close button to decide whether to prompt. We consider any change
    /// in min/max as unsaved.
    private var hasUnsavedRecording: Bool {
        guard canSaveCalibration else { return false }
        let saved = TouchpadService.shared.currentCalibration()
        return minX != saved.minX || maxX != saved.maxX
            || minY != saved.minY || maxY != saved.maxY
    }

    // MARK: - Calibration tab

    @ViewBuilder
    private var calibrationTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if savedCalibrationOnOpen.isUserCalibrated {
                savedCalibrationBanner
            }

            Text("Drag your finger across the entire touchpad until every cell is filled. JoystickConfig records the bounds and uses them so swipes feel uniform.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            calibrationPanel
                .aspectRatio(CGFloat(surfaceWidth) / CGFloat(surfaceHeight), contentMode: .fit)

            HStack(spacing: 20) {
                statBlock(label: "Coverage", value: "\(coveragePercent)%",
                          tint: coveragePercent >= minCoveragePercent ? .green : .secondary)
                statBlock(label: "X range",
                          value: minX <= maxX ? "\(minX) - \(maxX)" : "-",
                          tint: .secondary)
                statBlock(label: "Y range",
                          value: minY <= maxY ? "\(minY) - \(maxY)" : "-",
                          tint: .secondary)
                Spacer()
                if showSavedConfirmation {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Calibration saved")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .transition(.opacity)
                }
                Button("Reset", role: .destructive) { resetCalibration() }
                Button {
                    saveCalibration()
                } label: {
                    Label("Save Calibration", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveCalibration)
                .help(canSaveCalibration
                      ? "Save the calibrated bounds"
                      : "Drag your finger across the touchpad first to record an X / Y range")
            }
        }
    }

    /// Coverage threshold for enabling the Save button. Was 60% but that
    /// was too aggressive - most useful calibration sweeps land around 30-50%
    /// because edges of the touchpad rarely register on a casual drag.
    private let minCoveragePercent = 30

    /// Green pill at the top of the Calibration tab reminding the user that
    /// a calibration is already saved and showing its bounds + when it was
    /// last saved. Disappears when no calibration has ever been saved.
    private var savedCalibrationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibration saved and active")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("X range \(savedCalibrationOnOpen.minX) - \(savedCalibrationOnOpen.maxX)  •  Y range \(savedCalibrationOnOpen.minY) - \(savedCalibrationOnOpen.maxY)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let when = savedCalibrationOnOpen.savedAt {
                    Text("Last saved \(when, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.5), lineWidth: 1)
        )
    }

    private var calibrationPanel: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 10).stroke(Color.mint.opacity(0.6), lineWidth: 1.5)

                let cellW = geo.size.width / CGFloat(gridColumns)
                let cellH = geo.size.height / CGFloat(gridRows)
                ForEach(0..<(gridColumns * gridRows), id: \.self) { idx in
                    if touched[idx] {
                        let col = idx % gridColumns
                        let row = idx / gridColumns
                        Rectangle()
                            .fill(Color.mint.opacity(0.45))
                            .frame(width: cellW, height: cellH)
                            .position(x: cellW * (CGFloat(col) + 0.5),
                                      y: cellH * (CGFloat(row) + 0.5))
                    }
                }

                Path { path in
                    for i in 1..<gridColumns {
                        let x = cellW * CGFloat(i)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    for i in 1..<gridRows {
                        let y = cellH * CGFloat(i)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.mint.opacity(0.18), lineWidth: 1)

                fingerDots(in: geo.size)
            }
        }
    }

    // MARK: - Regions tab

    @ViewBuilder
    private var regionsTab: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(drawingNewRegion
                     ? "Click and drag on the touchpad surface to draw the new region."
                     : "Define named zones the controller's touchpad can act on. Bindings of type Touchpad Region will fire while a finger is inside.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                regionsPanel
                    .aspectRatio(CGFloat(surfaceWidth) / CGFloat(surfaceHeight), contentMode: .fit)

                HStack {
                    Button {
                        drawingNewRegion = true
                        dragStart = nil
                        dragCurrent = nil
                    } label: {
                        Label("Add Region", systemImage: "plus.rectangle")
                    }
                    .disabled(drawingNewRegion || regions.count >= 16)
                    if drawingNewRegion {
                        Button("Cancel") {
                            drawingNewRegion = false
                            dragStart = nil
                            dragCurrent = nil
                        }
                    }
                    Spacer()
                    Text("\(regions.count) / 16 regions")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            regionsList
                .frame(width: 240)
        }
    }

    private var regionsPanel: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 10).stroke(Color.mint.opacity(0.6), lineWidth: 1.5)

                // Existing regions
                ForEach(regions) { region in
                    let isPressed = TouchpadService.shared.isRegionPressed(region.id)
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

                // Drag-to-draw preview
                if drawingNewRegion, let start = dragStart, let current = dragCurrent {
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

                fingerDots(in: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(drawGesture(size: geo.size), including: drawingNewRegion ? .gesture : .none)
        }
    }

    private var regionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Defined Regions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
            if TouchpadService.shared.isRegionPressed(region.id) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
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

    // MARK: - Region drawing

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
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
                // Discard accidentally tiny regions.
                if (normMaxX - normMinX) > 0.04 && (normMaxY - normMinY) > 0.04 {
                    addRegion(minX: normMinX, maxX: normMaxX, minY: normMinY, maxY: normMaxY)
                }
                drawingNewRegion = false
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func addRegion(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let name = "Region \(regions.count + 1)"
        let colorIndex = regions.count % TouchpadRegion.colorPalette.count
        let region = TouchpadRegion(name: name, minX: minX, maxX: maxX,
                                     minY: minY, maxY: maxY, colorIndex: colorIndex)
        regions.append(region)
        selectedRegionID = region.id
        TouchpadService.shared.saveRegions(regions)
    }

    private func deleteRegion(_ id: UUID) {
        regions.removeAll { $0.id == id }
        if selectedRegionID == id { selectedRegionID = nil }
        TouchpadService.shared.saveRegions(regions)
    }

    private func commitRename(for id: UUID) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            regions[index].name = trimmed
            TouchpadService.shared.saveRegions(regions)
        }
        renamingRegionID = nil
        renamingText = ""
    }

    // MARK: - Shared bits

    @ViewBuilder
    private func fingerDots(in size: CGSize) -> some View {
        if let p = liveFinger0 {
            Circle()
                .fill(Color.mint)
                .frame(width: 18, height: 18)
                .position(x: p.x * size.width, y: p.y * size.height)
                .shadow(color: .mint.opacity(0.6), radius: 6)
        }
        if let p = liveFinger1 {
            Circle()
                .fill(Color.cyan)
                .frame(width: 14, height: 14)
                .position(x: p.x * size.width, y: p.y * size.height)
                .shadow(color: .cyan.opacity(0.5), radius: 5)
        }
    }

    private func statBlock(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.body.monospacedDigit()).foregroundStyle(tint)
        }
    }

    /// Map TouchpadRegion.colorIndex into a SwiftUI Color.
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

    // MARK: - Calibration logic

    private var coveragePercent: Int {
        let total = touched.count
        guard total > 0 else { return 0 }
        return Int(Double(touched.filter { $0 }.count) / Double(total) * 100)
    }

    private var canSaveCalibration: Bool {
        // Any valid range is allowed to save. We accept either:
        //   1. live recording during this session: real numbers in min/max
        //   2. pre-loaded saved calibration from `loadSavedCalibration`
        // The sentinel values are Int.max / Int.min, so this check is
        // equivalent to "we have real bounds to write".
        minX < maxX && minY < maxY
            && minX != .max && maxX != .min && minY != .max && maxY != .min
    }

    private func resetCalibration() {
        touched = Array(repeating: false, count: gridColumns * gridRows)
        minX = .max; maxX = .min; minY = .max; maxY = .min
        TouchpadService.shared.saveCalibration(.uncalibrated)
        savedCalibrationOnOpen = .uncalibrated
        showSavedConfirmation = false
    }

    /// Pre-populate the displayed X/Y bounds, coverage grid, and saved-at
    /// stamp from the persisted calibration. This way the cells the user
    /// previously filled are still painted when they reopen the sheet, and
    /// the coverage % reflects their actual sweep instead of resetting to 0.
    private func loadSavedCalibration() {
        let saved = TouchpadService.shared.currentCalibration()
        savedCalibrationOnOpen = saved
        guard saved.isUserCalibrated else { return }
        minX = saved.minX
        maxX = saved.maxX
        minY = saved.minY
        maxY = saved.maxY
        if let cells = saved.gridCells, cells.count == gridColumns * gridRows {
            touched = cells
        }
    }

    private func saveCalibration() {
        guard canSaveCalibration else { return }
        let toSave = TouchpadCalibration(minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                                          savedAt: Date(), gridCells: touched)
        TouchpadService.shared.saveCalibration(toSave)
        // Re-read what actually persisted so the banner reflects ground truth
        // (including the savedAt timestamp the service stamped).
        savedCalibrationOnOpen = TouchpadService.shared.currentCalibration()
        withAnimation(.easeIn(duration: 0.15)) {
            showSavedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showSavedConfirmation = false
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            pollOnce()
        }
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce() {
        let svc = TouchpadService.shared
        if let p = svc.currentPosition(finger: 0) {
            ingest(x: p.x, y: p.y)
            liveFinger0 = CGPoint(
                x: CGFloat(p.x) / CGFloat(surfaceWidth),
                y: CGFloat(p.y) / CGFloat(surfaceHeight))
        } else {
            liveFinger0 = nil
        }
        if let p = svc.currentPosition(finger: 1) {
            ingest(x: p.x, y: p.y)
            liveFinger1 = CGPoint(
                x: CGFloat(p.x) / CGFloat(surfaceWidth),
                y: CGFloat(p.y) / CGFloat(surfaceHeight))
        } else {
            liveFinger1 = nil
        }
    }

    private func ingest(x: Int, y: Int) {
        // Only record into the calibration grid when the user is on that
        // tab, so a finger drag in Regions mode doesn't pollute the cells.
        guard selectedTab == .calibration else { return }
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
        let col = max(0, min(gridColumns - 1,
                             Int(Double(x) / Double(surfaceWidth) * Double(gridColumns))))
        let row = max(0, min(gridRows - 1,
                             Int(Double(y) / Double(surfaceHeight) * Double(gridRows))))
        touched[row * gridColumns + col] = true
    }
}
