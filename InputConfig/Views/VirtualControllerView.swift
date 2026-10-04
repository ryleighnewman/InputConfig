import SwiftUI

/// Spoken forms of live values, coarse on purpose. VoiceOver re-announces
/// a focused element every time its value changes, and these values
/// change 30 to 60 times a second; two-decimal precision meant a stick at
/// rest produced a continuous stream and the visualizer could not be used
/// with VoiceOver at all. Cardinal words and 25 percent steps change
/// rarely and say more.
enum SpokenLive {
    /// "right 50 percent", "centered".
    static func stick(x: Float, y: Float) -> String {
        let mag = (x * x + y * y).squareRoot()
        guard mag > 0.15 else { return "centered" }
        let step = Int((min(1, mag) * 4).rounded()) * 25
        var dir: [String] = []
        if y < -0.35 { dir.append("up") } else if y > 0.35 { dir.append("down") }
        if x < -0.35 { dir.append("left") } else if x > 0.35 { dir.append("right") }
        return "\(dir.isEmpty ? "off center" : dir.joined(separator: " ")) \(step) percent"
    }
    /// A single signed axis in quarter steps: "plus 50 percent", "centered".
    static func axis(_ v: Float) -> String {
        let step = Int((min(1, abs(v)) * 4).rounded()) * 25
        guard step > 0 else { return "centered" }
        return "\(v < 0 ? "minus" : "plus") \(step) percent"
    }
    /// A trigger in quarter steps: "released", "50 percent", "fully pressed".
    static func trigger(_ v: Float) -> String {
        let step = Int((min(1, max(0, v)) * 4).rounded()) * 25
        switch step {
        case 0: return "released"
        case 100: return "fully pressed"
        default: return "\(step) percent"
        }
    }
    /// An angle to the nearest 15 degrees.
    static func degrees(_ radians: Float) -> Int {
        Int(((radians * 180 / .pi) / 15).rounded()) * 15
    }
}

import QuartzCore

/// Live virtual-controller layout. Reads the latest `ControllerState` from
/// `GameControllerService.currentStates[slot]` at 30 Hz and renders each
/// physical input as a clickable widget:
///
///   • Sticks - circle with a thumb dot that tracks the analog X/Y
///   • Triggers - vertical bar with the live magnitude + the binding's
///     deadzone threshold marked as a horizontal line
///   • Face buttons - circles that flash green on press
///   • Shoulders / bumpers - pill shapes
///   • D-pad - cross with each arm lighting up when active
///   • Touchpad - rectangle showing finger 1 / 2 positions
///   • Motion - gyroscope orb showing yaw / pitch deflection
///
/// Tapping a widget opens a popover summarizing any bindings in the
/// current preset that target that physical input, with a button to jump
/// into the preset editor focused on the relevant row.
/// The bits of a visualizer the host draws controls for (Edit Layout, the
/// zoom) outside the panel, on the Live Visualizer title row. One per
/// visualizer, owned by the host, observed by both.
final class VisualizerControlState: ObservableObject {
    @Published var editMode = false
    /// The size the map is drawn at, set by the zoom control on the host's
    /// title row (minus, slider, plus).
    @Published var scale: Double = 1.0
    /// Bumped by the host's Reset button; the panel clears its offsets.
    @Published var resetToken = 0
    /// The panel is drawing a controller model, whose controls stay where
    /// the real ones are, so there is little to rearrange.
    @Published var showingModel = false
}

/// The region editors a map's popover can open: Touchpad Setup for touchpad
/// zones, the drawing sheet for screen regions, the stick zone editor.
enum VisualizerRegionEditor {
    case touchpadSetup, screenRegions, stickZones

    var buttonTitle: String {
        switch self {
        case .touchpadSetup: return "Open Touchpad Setup"
        case .screenRegions: return "Edit screen regions"
        case .stickZones: return "Edit stick zones"
        }
    }

    var systemImage: String {
        switch self {
        case .touchpadSetup: return "rectangle.and.hand.point.up.left"
        case .screenRegions: return "rectangle.dashed"
        case .stickZones: return "circle.dashed"
        }
    }
}

/// The backdrop behind the visualizer map. Picked from the little circles
/// in the panel's top-right corner and kept across launches.
enum VisualizerBackground: String, CaseIterable, Identifiable {
    case normal, blueprint, black, slate

    var id: String { rawValue }
    static let storageKey = "InputConfig.visualizerBackground"

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .blueprint: return "Blueprint"
        case .black: return "Black"
        case .slate: return "Slate"
        }
    }

    /// The swatch color, and the panel fill for every theme but Normal
    /// (which keeps the window's own translucent fill).
    var swatch: Color {
        switch self {
        case .normal: return Color.secondary.opacity(0.35)
        case .blueprint: return Color(red: 0.07, green: 0.25, blue: 0.55)
        case .black: return Color(white: 0.04)
        case .slate: return Color(red: 0.16, green: 0.19, blue: 0.24)
        }
    }

    var fill: AnyShapeStyle {
        switch self {
        case .normal:
            return AnyShapeStyle(LinearGradient(
                colors: [Color.secondary.opacity(0.08), Color.secondary.opacity(0.03)],
                startPoint: .top, endPoint: .bottom))
        case .blueprint:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.09, green: 0.30, blue: 0.62), Color(red: 0.05, green: 0.20, blue: 0.46)],
                startPoint: .top, endPoint: .bottom))
        case .black:
            return AnyShapeStyle(Color(white: 0.04))
        case .slate:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.19, green: 0.22, blue: 0.28), Color(red: 0.13, green: 0.15, blue: 0.20)],
                startPoint: .top, endPoint: .bottom))
        }
    }

    /// Grid line color: white on the colored papers, the neutral
    /// secondary on Normal.
    var gridColor: Color {
        switch self {
        case .normal: return .secondary
        case .blueprint: return .white
        case .black: return Color(white: 0.75)
        case .slate: return .white
        }
    }

    var gridBoost: Double { self == .normal ? 1 : 1.6 }
}

struct VirtualControllerView<Trailing: View>: View {
    @EnvironmentObject var controllerService: GameControllerService
    @EnvironmentObject var mappingEngine: MappingEngine
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let preset: Preset
    /// Asks the host to open the preset editor and scroll/pulse the row that
    /// matches this input. Fired when the user clicks any matching binding
    /// in a widget popover, OR the "Jump to editor anyway" button when no
    /// binding currently targets the input.
    var onJump: ((EditorJumpTarget) -> Void)?
    /// Attached displays and the pointer's display, for the Screen template.
    /// Not observed: the pointer position it publishes at 60 Hz rebuilt the
    /// whole visualizer on every move. Only the display list is read here.
    private var cursorService: CursorRegionService { .shared }
    /// The Mac's own keyboard and mouse. Not observed here: every pointer
    /// move and scroll tick is a live input, and observing it rebuilt the
    /// whole visualizer (the one under an open editor too) up to 30 times a
    /// second while scrolling. Only the keyboard and mouse diagrams observe
    /// it, through ExternalInputObserver.
    private var externalInput: ExternalInputDeviceService { .shared }
    /// Published, so the note goes away the moment the permission is granted.
    @ObservedObject private var accessibility = AccessibilityPermissionService.shared
    /// This instance's name on the keyboard / mouse monitor. Unique per
    /// instance: when a preset changes, the old visualizer's disappear
    /// can run after the new one's appear, and a shared name let that
    /// late release wipe the new hold.
    @State private var externalHold = "visualizer-" + UUID().uuidString
    /// The Face button names setting, observed so the drawn letters change
    /// the moment it does.
    @AppStorage(FaceLetters.defaultsKey) private var faceLettersRaw = FaceLetters.automatic.rawValue
    /// True while something covers the visualizer (the editor sheet).
    @Environment(\.visualizerSuspended) private var visualizerSuspended

    /// Which controller slot this visualizer mirrors. Hosts may render
    /// one visualizer per connected controller and pass the slot in
    /// directly; the legacy slot picker is hidden when this is non-nil.
    var fixedSlot: Int?

    /// Content shown as a popover anchored to the light-bar strip on the
    /// controller. ContentView feeds the per-preset Light Bar editor here
    /// for controllers that have a real light bar (DualSense / DualShock 4).
    /// EmptyView for everyone else.
    @ViewBuilder var trailing: () -> Trailing

    /// Tint of the on-controller light-bar strip widget. ContentView
    /// computes this from the preset's `lightBarColor` override - nil =
    /// use a faint neutral fill so the strip is visible but obviously
    /// "unset". When set, the strip glows that color.
    var lightBarTint: Color? = nil
    /// The preset cycles the light bar through every color (its rainbow),
    /// so the strip shows a rainbow swatch instead of one color.
    var lightBarRainbow: Bool = false
    /// The preset's light is set to off (black, or brightness Off).
    var lightBarOff: Bool = false

    /// Optional callback: when the user picks a new layout template
    /// from the inline visualizer picker, this fires with the slot
    /// and the new `SlotInputKind`. Host updates the preset model
    /// via the store. nil hides the picker.
    var onChangeInputKind: ((Int, SlotInputKind) -> Void)?
    /// Optional callback for the Buttons menu beside the template picker:
    /// the controller family the preset is made for (nil is Automatic).
    /// nil hides the menu.
    var onChangeButtonFamily: ((FaceLetters?) -> Void)? = nil
    /// Sets the controller model a group is drawn as (nil: automatic).
    var onChangeControllerModel: ((Int, ControllerModelID?) -> Void)? = nil
    /// Points a group at a connected controller by the name its device menu
    /// uses (nil: Automatic, the pad at its own number).
    var onChangeDevice: ((Int, String?) -> Void)? = nil
    /// Opens a region editor (Touchpad Setup, the screen region drawing
    /// sheet, the stick zone editor) from a zone's or region's popover.
    /// nil hides those buttons.
    var onOpenRegionEditor: ((VisualizerRegionEditor) -> Void)? = nil

    /// Edit mode and zoom live with the host, which draws their controls on
    /// the Live Visualizer title row; the panel reads and writes them here.
    @ObservedObject var control: VisualizerControlState
    private var visualizerScale: Double {
        get { control.scale }
        nonmutating set { control.scale = newValue }
    }
    private var editMode: Bool {
        get { control.editMode }
        nonmutating set { control.editMode = newValue }
    }
    @AppStorage(VisualizerBackground.storageKey) private var backgroundChoice: String = VisualizerBackground.normal.rawValue
    private var background: VisualizerBackground {
        VisualizerBackground(rawValue: backgroundChoice) ?? .normal
    }

    /// Where the map has been dragged to inside the panel (grab any empty
    /// spot and move it). Kept with the zoom per preset and group, so a
    /// panel opens the way it was left; Reset View puts both back.
    @State private var panOffset: CGSize = .zero
    @State private var dragInProgress: CGSize = .zero
    /// The closed hand is up while a drag is under way.
    @State private var panCursorPushed = false
    #if DEBUG
    @State private var debugCursorRegionSize: Double?
    #endif
    /// Set while a saved view is being put back, so loading the zoom does
    /// not write it straight back out.
    @State private var restoringView = false

    /// Where this panel's pan and zoom are kept: per preset and group.
    private var viewStorageKey: String { "InputConfig.visualizerView.\(preset.id.uuidString).\(slot)" }

    /// How far the map can be dragged off center, so it can never be lost.
    private var panLimit: CGFloat { 900 }

    private func loadView() {
        restoringView = true
        if let saved = UserDefaults.standard.dictionary(forKey: viewStorageKey) as? [String: Double] {
            panOffset = CGSize(width: saved["x"] ?? 0, height: saved["y"] ?? 0)
            control.scale = min(1.5, max(0.3, saved["scale"] ?? 1))
        } else {
            panOffset = .zero
            control.scale = 1
        }
        DispatchQueue.main.async { restoringView = false }
    }

    private func saveView() {
        guard !restoringView else { return }
        if panOffset == .zero && control.scale == 1 {
            UserDefaults.standard.removeObject(forKey: viewStorageKey)
        } else {
            UserDefaults.standard.set(["x": Double(panOffset.width), "y": Double(panOffset.height), "scale": control.scale],
                                      forKey: viewStorageKey)
        }
    }

    private func clampedPan(_ size: CGSize) -> CGSize {
        CGSize(width: min(panLimit, max(-panLimit, size.width)),
               height: min(panLimit, max(-panLimit, size.height)))
    }

    /// Popover state for the on-controller light-bar widget.
    @State private var showLightBarPopover: Bool = false

    /// Transient feedback after the user clicks "Reset gyroscope" in
    /// the Motion popover. Shows for ~1.5s then clears.
    @State private var gyroResetFeedback: String?

    /// Integrated gyro orientation (radians). Owned at this level so the
    /// integrator timer is created exactly ONCE (placing it inside
    /// MotionWidget caused it to be recreated on every 30 Hz render of
    /// the parent TimelineView, which destabilized the subscription and
    /// made the model freeze after the first tick).
    @State private var integratedRoll: Float = 0
    @State private var integratedPitch: Float = 0
    @State private var integratedYaw: Float = 0

    @State private var slotState: Int = 0
    private var slot: Int { fixedSlot ?? slotState }
    /// Per-widget open-popover flags. Keyed by widget label so each widget
    /// owns its own popover anchored at its own bounds (no more popovers
    /// flying to the center of the screen).
    @State private var openInspectorLabel: String?

    // MARK: - Drag-to-rearrange

    /// True when the user has flipped the visualizer into "Customize layout"
    /// mode. While on, every widget sprouts a dashed yellow outline and can
    /// be dragged around. Clicks open the popover as usual when off.
    /// Per-widget offsets from each widget's structural position. Persisted
    /// to UserDefaults per controller model so each controller remembers its
    /// custom layout independently.
    @State private var dragOffsets: [String: CGSize] = [:]
    /// Live offset while the user is mid-drag, so the widget tracks the
    /// finger before we commit the new persisted offset on drag-end.
    @State private var liveDrag: (label: String, translation: CGSize)?

    /// UserDefaults key for this controller model's saved offsets.
    private var layoutStorageKey: String {
        let category = controllerService.controllerDetails[deviceSlot]?.productCategory ?? "Default"
        return "VirtualController.layout.\(category)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Edit Layout, the zoom, and the device name are drawn by the
            // host on the Live Visualizer title row (see
            // VisualizerHeaderControls), so the panel starts right here.

            // The panel's menu, outside the zoomed and panned map and its
            // 30 Hz clock: inside, its click area drifted from where it was
            // drawn whenever the zoom was not 1x (clicks on its right side
            // missed), and it was rebuilt every frame while inputs moved,
            // which closed submenus as they opened.
            if onChangeInputKind != nil { templatePicker }

            // Visualizer panel. The gradient/grid background must follow
            // the actually-rendered (scaled) contents - not the outer
            // frame - or the user sees empty backdrop around shrunk
            // contents, or contents bleed past a too-small backdrop
            // when zoomed in.
            //
            // Order matters: padding → background (sized to padded
            // contents) → scaleEffect (scales background + contents
            // together) → offset (pans the whole thing). The outer
            // .frame just centers the scaled block within the column.
            // CRITICAL: the visualizer's 30 fps clock PAUSES when the
            // controller is idle. An always-on TimelineView re-laid-out the
            // full widget tree 30x/second even for untouched controllers
            // (pinning a core); a pure change-gate was choppy because SwiftUI
            // doesn't invalidate on writes to state the body never reads.
            // This hybrid keeps a real time-driven clock for buttery motion
            // and flips `visualizerIdle` (which the body DOES read, via
            // `paused:`) after ~0.7 s without a visible state change.
            // Also paused while another app is in front: nobody is looking,
            // and a full relayout of this panel 30 times a second was
            // starving the engine's poll timer on the main thread, which
            // reached the pointer as a stutter in exactly the situation the
            // app exists for (driving another app from the controller).
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: visualizerIdle || info == nil || !appIsActive || visualizerSuspended)) { _ in
                visualizerPanelContent
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appIsActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appIsActive = false }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            // The fixed viewport box. Sits on the outer frame so it never scales
            // with the zoom, giving the map a stationary container.
            .background(visualizerBoxBackground)
            // Hard-clip the map to that box. The zoom uses .scaleEffect, a
            // render-only transform that does NOT shrink the view's layout
            // footprint, so a zoomed-in map paints past its bounds and, without
            // this, spills over the sidebar, header, and rows out onto the window.
            // .clipped() is unreliable here: its rectangular clip can fail to mask
            // a child .scaleEffect layer, which composites outside it. An explicit
            // .clipShape forces a real mask layer the scaled content must render
            // into, so every pixel stays inside the box.
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .topTrailing) { backgroundSwatches }
            .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main,
                                     in: .common).autoconnect()) { _ in
                // Nobody is looking while another app is in front, and the
                // clock above is paused then too.
                guard info != nil, appIsActive, !visualizerSuspended else { return }
                // A finger on a PlayStation touchpad changes no state the
                // pad reports, so its position counts too: the clock then
                // runs while a finger moves and idles when none does.
                var sig = Self.renderSignature(state)
                if info?.hasTouchpad == true {
                    for f in 0..<2 {
                        if let p = TouchpadService.shared.currentPosition(finger: f) {
                            var h = Hasher(); h.combine(4); h.combine(f); h.combine(p.x / 8); h.combine(p.y / 8)
                            sig ^= h.finalize()
                        }
                    }
                }
                if sig != lastRenderSignature {
                    lastRenderSignature = sig
                    lastSignatureChangeAt = CACurrentMediaTime()
                    if visualizerIdle { visualizerIdle = false }
                } else if !visualizerIdle,
                          CACurrentMediaTime() - lastSignatureChangeAt > 0.7 {
                    visualizerIdle = true
                }
            }
            // Grab the map anywhere in the box and move it. The whole box
            // takes the drag: without the shape, only the drawn controls
            // could be grabbed and the empty space around them let the drag
            // fall through. A control's own click or drag (Edit Layout)
            // still comes first.
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if !panCursorPushed { NSCursor.closedHand.push(); panCursorPushed = true }
                        let total = clampedPan(CGSize(width: panOffset.width + value.translation.width,
                                                      height: panOffset.height + value.translation.height))
                        dragInProgress = CGSize(width: total.width - panOffset.width, height: total.height - panOffset.height)
                    }
                    .onEnded { value in
                        panOffset = clampedPan(CGSize(width: panOffset.width + value.translation.width,
                                                      height: panOffset.height + value.translation.height))
                        dragInProgress = .zero
                        if panCursorPushed { NSCursor.pop(); panCursorPushed = false }
                        saveView()
                    }
            )
            .overlay(alignment: .bottomLeading) {
                if panOffset != .zero || control.scale != 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            panOffset = .zero
                            control.scale = 1
                        }
                        saveView()
                    } label: {
                        Label("Reset View", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .help("Put the map back in the middle at its normal size")
                    .padding(10)
                }
            }

            if editMode {
                Text("Drag any widget to a new position. The layout saves automatically for this controller model.")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .padding(.top, 2)
            }
        }
        .onAppear {
            loadOffsets()
            loadView()
            controllerService.retainLiveInput(externalHold)
        }
        .onDisappear {
            if panCursorPushed { NSCursor.pop(); panCursorPushed = false }
            controllerService.releaseLiveInput(externalHold)
            ExternalInputDeviceService.shared.release(externalHold)
        }
        // Hold the Mac's keyboard or mouse monitor open while that template
        // is up, so keys and clicks show live with nothing running. Not
        // under the editor, where the hidden map would redraw on every
        // scroll and keystroke (the editor holds its own when it needs one).
        .task(id: "\(effectiveInputKind)|\(visualizerSuspended)") {
            if visualizerSuspended {
                ExternalInputDeviceService.shared.release(externalHold)
            } else {
                ExternalInputDeviceService.shared.retain(externalHold,
                                                         mouse: effectiveInputKind == .mouse,
                                                         keyboard: effectiveInputKind == .keyboard)
            }
        }
        .onChange(of: control.scale) { _, _ in saveView() }
        .onChange(of: preset.id) { _, _ in loadView() }
        .onChange(of: slot) { _, _ in
            loadOffsets()
            loadView()
            // Different controller, different orientation context. Reset
            // so the new controller starts from neutral.
            integratedRoll = 0
            integratedPitch = 0
            integratedYaw = 0
        }
        // Single stable 30 Hz integrator. Reads the latest gyro rates
        // from controllerService.currentStates each tick and accumulates
        // into the @State angle vars - which MotionWidget below reads.
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            guard appIsActive, !visualizerSuspended else { return }
            let s = state
            let gx = s.motion[.gyroX] ?? 0
            let gy = s.motion[.gyroY] ?? 0
            let gz = s.motion[.gyroZ] ?? 0
            // Idle gate with a NOISE DEADBAND, not an exact-zero test: a real
            // controller's gyro reports tiny nonzero noise on every sample, so
            // == 0 never triggered and the integrator dirtied this whole view
            // 30x/second while two controllers sat untouched (main thread
            // pegged, app-wide lag). Below the deadband there is no visible
            // motion to integrate, so skip the @State writes entirely.
            let deadband: Float = 0.02
            // Pitch comes fused with the accelerometer when the service has
            // it, so the model settles back to flat exactly like the pointer.
            if let absolute = s.motion[.pitchAngle] {
                let fused = absolute * (.pi / 2)
                if abs(fused - integratedPitch) > 0.005 { integratedPitch = fused }
            }
            if abs(gx) < deadband && abs(gy) < deadband && abs(gz) < deadband { return }
            let dt: Float = 1.0 / 30.0
            // gyroZ turns about the axis out of the pad's face, which is
            // yaw for a pad held flat (the engine's yaw channel too), and
            // gyroY is roll. These two were swapped.
            if s.motion[.pitchAngle] == nil { integratedPitch += gx * dt }
            integratedYaw   += gz * dt
            integratedRoll  += gy * dt
            integratedPitch = max(-(.pi / 2), min(.pi / 2, integratedPitch))
            integratedYaw   = max(-(.pi / 2), min(.pi / 2, integratedYaw))
            integratedRoll  = max(-(.pi / 2), min(.pi / 2, integratedRoll))
        }
        .onReceive(NotificationCenter.default.publisher(for: GameControllerService.motionRezeroedNotification)) { _ in
            // Re-zero pressed: the controller's current pose is the new
            // neutral for the model too.
            integratedRoll = 0
            integratedPitch = 0
            integratedYaw = 0
        }
        .onChange(of: control.resetToken) { _, _ in
            dragOffsets.removeAll()
            persistOffsets()
        }
        .onChange(of: control.editMode) { _, editing in
            openInspectorLabel = nil
            _ = editing
        }
        .debugEditLayout($control.editMode)
        .debugVizZoom($control.scale)
        #if DEBUG
        .onReceive(DebugMarketing.shared.$cursorRegionSize) { debugCursorRegionSize = $0 }
        #endif
    }

    // MARK: - Background choice

    /// Little circles in the panel's top-right corner, one per backdrop.
    /// The chosen one wears a ring.
    private var backgroundSwatches: some View {
        HStack(spacing: 6) {
            ForEach(VisualizerBackground.allCases) { choice in
                Button {
                    backgroundChoice = choice.rawValue
                } label: {
                    Circle()
                        .fill(choice.swatch)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle().strokeBorder(
                                background == choice ? Color.primary.opacity(0.9) : Color.primary.opacity(0.25),
                                lineWidth: background == choice ? 1.5 : 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("\(choice.label) background")
                .accessibilityLabel("\(choice.label) background")
                .accessibilityAddTraits(background == choice ? .isSelected : [])
            }
        }
        .padding(8)
        .zIndex(3)
    }

    /// Always-on light gray grid overlay. The lines are very faint by
    /// default so they read as background texture; in customize mode
    /// they brighten to provide a clear "workbench" feel for the drag
    /// interaction.
    private var gridOverlay: some View {
        Canvas { context, size in
            let minorOpacity: Double = (editMode ? 0.18 : 0.06) * background.gridBoost
            let majorOpacity: Double = (editMode ? 0.32 : 0.10) * background.gridBoost
            let minor = background.gridColor.opacity(minorOpacity)
            let major = background.gridColor.opacity(majorOpacity)
            let minorStep: CGFloat = 20
            let majorStep: CGFloat = 100

            // Minor grid (faint).
            var minorPath = Path()
            var x: CGFloat = 0
            while x <= size.width {
                minorPath.move(to: CGPoint(x: x, y: 0))
                minorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += minorStep
            }
            var y: CGFloat = 0
            while y <= size.height {
                minorPath.move(to: CGPoint(x: 0, y: y))
                minorPath.addLine(to: CGPoint(x: size.width, y: y))
                y += minorStep
            }
            context.stroke(minorPath, with: .color(minor), lineWidth: 0.5)

            // Major grid (slightly bolder).
            var majorPath = Path()
            x = 0
            while x <= size.width {
                majorPath.move(to: CGPoint(x: x, y: 0))
                majorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += majorStep
            }
            y = 0
            while y <= size.height {
                majorPath.move(to: CGPoint(x: 0, y: y))
                majorPath.addLine(to: CGPoint(x: size.width, y: y))
                y += majorStep
            }
            context.stroke(majorPath, with: .color(major), lineWidth: 1.0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Layout

    /// Pauses the visualizer's 30 fps TimelineView when the controller has
    /// shown no visible change for ~0.7 s. Read by the body (via `paused:`)
    /// so transitions re-render correctly.
    @State private var visualizerIdle: Bool = true
    /// Whether this app is the frontmost one; the clock pauses when it is not.
    @State private var appIsActive: Bool = NSApp.isActive
    /// Last quantized state fingerprint + when it last moved. Plain change
    /// bookkeeping for the idle detector.
    @State private var lastRenderSignature: Int = 0
    @State private var lastSignatureChangeAt: CFTimeInterval = 0

    private var state: ControllerState {
        #if DEBUG
        // Marketing capture: currentStates is only filled by the live poll, so
        // without this the visualizer sits at 0% while the sidebar already
        // shows the synthetic controllers.
        if controllerService.debugMarketingFakeActive,
           let synthetic = controllerService.peekControllerState(at: slot) {
            return synthetic
        }
        #endif
        // The device this group reads, so its presses light here and not
        // on another group's map.
        return controllerService.currentStates[deviceSlot] ?? ControllerState()
    }

    /// Order-independent hash of the state with every float snapped to a
    /// 0.02 grid, so sensor noise (gyro jitter, stick drift) below visible
    /// motion does not count as a change.
    private static func renderSignature(_ s: ControllerState) -> Int {
        func q(_ v: Float) -> Int { Int((v * 50).rounded()) }
        var acc = 0
        for (k, v) in s.buttons {
            var h = Hasher(); h.combine(0); h.combine(k); h.combine(q(v))
            acc ^= h.finalize()
        }
        for (k, v) in s.axes {
            var h = Hasher(); h.combine(1); h.combine(k); h.combine(q(v))
            acc ^= h.finalize()
        }
        for (k, v) in s.hats {
            var h = Hasher(); h.combine(2); h.combine(k)
            h.combine(q(v.x)); h.combine(q(v.y))
            acc ^= h.finalize()
        }
        for (k, v) in s.motion {
            // Motion channels get a coarser 0.1 grid: gyro/attitude sensor
            // noise straddles 0.02 bins constantly, which kept the fingerprint
            // flickering and defeated the idle pause whenever a DualSense was
            // connected. Visible rotation easily exceeds 0.1; noise does not.
            var h = Hasher(); h.combine(3); h.combine(k)
            h.combine(Int((v * 10).rounded()))
            acc ^= h.finalize()
        }
        return acc
    }

    private var info: ControllerInfo? {
        controllerService.controllerDetails[deviceSlot]
    }

    /// The effective input kind for the slot's visualizer. User-set
    /// `inputKind` on the JoystickMapping takes priority; .auto falls
    /// back to inferring from the binding-type majority.
    private var effectiveInputKind: SlotInputKind {
        let slotJoystick = (slot < preset.joysticks.count)
            ? preset.joysticks[slot] : nil
        guard let j = slotJoystick else { return .controller }
        // A slot whose rows are all screen regions is the screen, whatever
        // template it was pinned to. Presets from before the Screen
        // template existed were pinned to Touchpad, and a touchpad drawing
        // of the display is the wrong picture.
        if !j.bindings.isEmpty, j.bindings.allSatisfy({ $0.input.type == .cursorRegion }) { return .screen }
        if j.inputKind != .auto { return j.inputKind }
        guard !j.bindings.isEmpty else { return .controller }
        var counts: [SlotInputKind: Int] = [:]
        for b in j.bindings {
            switch b.input.type {
            case .extKey:
                counts[.keyboard, default: 0] += 1
            case .extMouse:
                counts[.mouse, default: 0] += 1
            case .touchpad, .touchpadRegion, .touchpadGesture:
                counts[.touchpad, default: 0] += 1
            case .cursorRegion:
                counts[.screen, default: 0] += 1
            case .midi:
                counts[.midi, default: 0] += 1
            default:
                counts[.controller, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? .controller
    }

    /// The visualizer panel chrome + content, extracted so the live
    /// (TimelineView) and static (no controller) paths render the exact
    /// same thing.
    private var visualizerPanelContent: some View {
        // ONLY the controller map scales and pans. The gradient/grid box used to
        // live inside this scaleEffect, so the box itself grew with the zoom and,
        // past ~1x, its edges scaled clean out of the visible frame - leaving the
        // map with no stationary container and painting out over the sidebar and
        // window. The box is now a FIXED backdrop applied on the outer frame (see
        // body), so it stays put as a viewport and the zoomed map is clipped
        // inside it. Nothing here changes the view's layout footprint, which is
        // what lets that outer clip actually contain the scaled render.
        controllerLayout
            // Hold the map to a controller-sized column. Without this the
            // spacers between the widget groups stretch to the panel's full
            // width, which scattered the triggers to the far edges and left
            // a hole in the middle.
            .frame(maxWidth: 520)
            .padding(18)
            .scaleEffect(visualizerScale, anchor: .center)
            .offset(x: panOffset.width + dragInProgress.width,
                    y: panOffset.height + dragInProgress.height)
            // Zoomed, the map is drawn as one picture at its final size, so
            // text and lines stay sharp: scaleEffect alone magnified what was
            // drawn at 100% and blurred it. The picture spans the whole box,
            // so the zoomed map is not cut short at its own column. Not the
            // screen regions map, whose display menu is an AppKit control a
            // drawing group cannot show.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(SharpZoom(active: visualizerScale != 1 && effectiveInputKind != .screen))
    }

    /// The stationary gradient + grid + border backdrop the visualizer map sits
    /// inside. It is applied to the outer frame (not the scaled content), so it
    /// never zooms: it is the fixed viewport that bounds the map. The grid reads
    /// as stable workbench paper the controller scales and pans across.
    private var visualizerBoxBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(background.fill)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.18),
                            lineWidth: 0.5)
            )
            .overlay(gridOverlay)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var controllerLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Layout choice is driven by the slot's `inputKind` (which the
            // user can set explicitly from the visualizer's template
            // picker OR from the slot's device menu), with a fallback
            // to inferring from binding types. Each widget then gates
            // on (a) hardware capability and (b) binding presence.
            switch effectiveInputKind {
            case .midi:
                MIDIInstrumentView(preset: preset, slot: slot, onJump: onJump)
            case .keyboard:
                keyboardLayout
            case .touchpad:
                touchpadLayout
            case .mouse:
                mouseLayout
            case .screen:
                screenLayout
            case .controller, .auto:
                if info == nil && !slotHasAnyBinding && (slot >= preset.joysticks.count || preset.joysticks[slot].controllerModel == nil) {
                    emptyVisualizerPlaceholder
                } else if slotIsMacTapsOnly {
                    // Tap the Mac: the input is the computer itself, so a
                    // controller drawing here would be about nothing. The
                    // tap map below is the whole picture.
                    EmptyView()
                } else if let resolved = resolvedLayout, resolved.layout.isComplete {
                    canvas(resolved)
                        .onAppear { control.showingModel = true }
                        .onDisappear { control.showingModel = false }
                } else {
                    controllerWidgets
                }
            }
            // The regions this preset defines, whichever template is up:
            // screen areas and stick zones draw their own maps (touchpad
            // zones are drawn on the touchpad widget itself).
            regionMaps
        }
    }

    /// Maps for the region kinds the preset defines. Each one lights the
    /// region the live point is inside, so the visualizer answers "which
    /// zone am I in" without running the preset.
    @ViewBuilder
    private var regionMaps: some View {
        // Screen regions are not here: the display is its own template
        // (`screenLayout`), so a controller's pad never has a screen map
        // hanging under it.
        if boundTapCounts.isEmpty == false {
            TapMapView(counts: boundTapCounts)
        }
        ForEach(stickRegionMaps, id: \.stick) { entry in
            RegionMapView(title: entry.stick == 0 ? "Left stick zones" : "Right stick zones",
                          systemImage: "circle.dashed",
                          aspect: 1,
                          regions: entry.regions,
                          point: entry.point,
                          pointLabel: entry.stick == 0 ? "Left stick" : "Right stick",
                          onPick: { region in
                              jumpToInput(InputEvent.stickRegion(stickIndex: entry.stick, id: region.id))
                          },
                          inspect: { region, swatch in
                              AnyView(inspectable(label: region.name, key: "stickzone-\(region.id)",
                                                  events: [InputEvent.stickRegion(stickIndex: entry.stick, id: region.id)],
                                                  draggable: false, editor: .stickZones) { swatch })
                          })
        }
    }

    /// Everything a touch surface can be bound to in this preset: the
    /// finger axes, the physical press, every zone the preset defines, and
    /// the tap gestures. The inspector lists rows for all of them, so
    /// clicking the pad finds a zone or a two-finger tap row, which it
    /// could not before: only the axes and the press were listed.
    private var touchpadInspectEvents: [InputEvent] {
        // Both fingers, both axes, both directions: a row on finger 2 or
        // on a negative direction was left out and the popover said
        // "No bindings".
        var events: [InputEvent] = []
        for finger in 0..<2 {
            for axis in TouchpadAxis.allCases {
                for direction in AxisDirection.allCases {
                    events.append(.touchpad(finger: finger, axis: axis, direction: direction))
                }
            }
        }
        events.append(.button(capabilities.touchpadPressIndex))
        events += preset.touchpadRegions.map { InputEvent.touchpadRegion($0.id) }
        events += TouchpadGestureKind.allCases.map { InputEvent.touchpadGesture($0) }
        return events
    }

    /// Shape of the surface this slot is showing. The Mac's own trackpad is
    /// not the same shape as a controller pad.
    private var touchpadSurfaceAspect: CGFloat {
        capabilities.touchpad ? 220.0 / 70.0 : 1.6
    }

    /// Drawn height of that surface, matching TouchpadWidget's own sizing.
    private var touchpadPadHeight: CGFloat {
        max(60, min(150, 220.0 / max(0.6, touchpadSurfaceAspect)))
    }

    /// The zone a region input points at, as the preset defines it: its
    /// name and the palette slot the maps draw it in. Nil for anything
    /// that is not a region.
    private func regionInfo(for input: InputEvent) -> (name: String, colorIndex: Int)? {
        if let id = input.touchpadRegionID,
           let r = preset.touchpadRegions.first(where: { $0.id == id }) {
            return (r.name, r.colorIndex)
        }
        if let id = input.cursorRegionID,
           let r = preset.cursorRegions.first(where: { $0.id == id }) {
            return (r.name, r.colorIndex)
        }
        if let id = input.stickRegionID {
            for (_, list) in preset.stickRegions {
                if let r = list.first(where: { $0.id == id }) { return (r.name, r.colorIndex) }
            }
        }
        return nil
    }

    /// Go to the row that binds this input. The row can live in any group,
    /// so the whole preset is searched before falling back to this slot:
    /// a screen region is usually bound once and shared, not per device.
    private func jumpToInput(_ event: InputEvent) {
        let serialized = event.serialized
        for (g, group) in preset.joysticks.enumerated()
        where group.bindings.contains(where: { $0.input.serialized == serialized }) {
            onJump?(EditorJumpTarget(joystickIndex: g, inputSerialized: serialized))
            return
        }
        onJump?(EditorJumpTarget(joystickIndex: slot, inputSerialized: serialized))
    }

    /// The display which the screen map shows, chosen by the user and
    /// remembered; empty means the map follows the pointer between displays.
    @AppStorage("InputConfig.visualizer.screenDisplay") private var screenDisplayName: String = ""

    private var chosenScreenDisplay: DisplayKey? {
        guard !screenDisplayName.isEmpty else { return nil }
        return cursorService.attachedDisplays.first { $0.key.name == screenDisplayName }?.key
    }

    /// The Screen template: one display, drawn in its real shape, with the
    /// preset's regions on it and the pointer as the live point. The
    /// display is picked here rather than inferred from where the pointer
    /// happens to be, so a region drawn for the external monitor can be
    /// looked at while the pointer is on the laptop.
    /// The preset's screen regions as the map draws them. DEBUG builds can
    /// draw corner regions larger for a capture (DebugMarketing).
    private var drawnCursorRegions: [TouchpadRegion] {
        #if DEBUG
        if let size = debugCursorRegionSize {
            return preset.cursorRegions.map { r in
                var g = r
                if r.minX <= 0.001 { g.maxX = max(r.maxX, size) } else if r.maxX >= 0.999 { g.minX = min(r.minX, 1 - size) }
                if r.minY <= 0.001 { g.maxY = max(r.maxY, size) } else if r.maxY >= 0.999 { g.minY = min(r.minY, 1 - size) }
                return g
            }
        }
        #endif
        return preset.cursorRegions
    }

    @ViewBuilder
    private var screenLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Screen regions", systemImage: "rectangle.dashed")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Button {
                        screenDisplayName = ""
                    } label: {
                        if chosenScreenDisplay == nil { Label("Follow the pointer", systemImage: "checkmark") } else { Text("Follow the pointer") }
                    }
                    Divider()
                    ForEach(cursorService.attachedDisplays) { d in
                        Button {
                            screenDisplayName = d.key.name
                        } label: {
                            if chosenScreenDisplay == d.key { Label(d.key.name, systemImage: "checkmark") } else { Text(d.key.name) }
                        }
                    }
                } label: {
                    Label(chosenScreenDisplay?.name ?? "Follow the pointer", systemImage: "display")
                        .font(.caption)
                }
                .fixedSize()
                .help("Which display the map shows. Follow the pointer switches as the pointer moves between displays.")
                Text("\(preset.cursorRegions.count) region\(preset.cursorRegions.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // The live screen shows whether or not there are regions yet, with
            // a one-click way to draw one: it opens the editor with a Screen
            // region row added and the drawing sheet up.
            HStack(spacing: 8) {
                Button {
                    jump(EditorJumpTarget(joystickIndex: slot, inputSerialized: "", action: .addScreenRegion))
                } label: {
                    Label(preset.cursorRegions.isEmpty ? "Draw a screen region" : "Draw another region",
                          systemImage: "plus.rectangle.on.rectangle")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondaryCompact)
                // A preset holds 16 regions, as the drawing sheet does.
                .disabled(preset.cursorRegions.count >= 16)
                .help(preset.cursorRegions.count >= 16 ? "This preset has the most regions it can hold, 16"
                      : "Opens the editor with a Screen region row added and the drawing sheet open")
                if preset.cursorRegions.isEmpty {
                    Text("Move the pointer into a region to fire its row.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            do {
                HStack {
                    Spacer(minLength: 0)
                    RegionMapView(title: "",
                                  systemImage: "rectangle.dashed",
                                  aspect: 16.0 / 10.0,
                                  regions: drawnCursorRegions,
                                  point: .zero,
                                  pointLabel: "Pointer",
                                  liveCursor: true,
                                  displayOverride: chosenScreenDisplay,
                                  large: true,
                                  onPick: { region in
                                      jumpToInput(InputEvent.cursorRegion(region.id))
                                  },
                                  inspect: { region, swatch in
                                      AnyView(inspectable(label: region.name, key: "screen-\(region.id)",
                                                          events: [InputEvent.cursorRegion(region.id)],
                                                          draggable: false, editor: .screenRegions) { swatch })
                                  })
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// True when every row in this slot listens to the Mac's own chassis,
    /// so there is no controller to draw.
    private var slotIsMacTapsOnly: Bool {
        guard slot < preset.joysticks.count else { return false }
        let rows = preset.joysticks[slot].bindings
        return !rows.isEmpty && rows.allSatisfy { $0.input.type == .chassisTap }
    }

    /// Tap counts this slot binds, so a Tap the Mac preset shows what a
    /// knock does and which one just landed.
    private var boundTapCounts: [Int] {
        guard slot < preset.joysticks.count else { return [] }
        let counts = preset.joysticks[slot].bindings
            .filter { $0.input.type == .chassisTap }
            .map { max(1, min(5, $0.input.index)) }
        return Array(Set(counts)).sorted()
    }

    /// The preset's stick zones with the live stick position, per stick.
    private var stickRegionMaps: [(stick: Int, regions: [TouchpadRegion], point: CGPoint)] {
        preset.stickRegions.compactMap { key, list in
            guard let stick = Int(key), !list.isEmpty else { return nil }
            let x = Double(state.axes[stick * 2] ?? 0)
            let y = Double(state.axes[stick * 2 + 1] ?? 0)
            // Axis values run -1...1; the maps are drawn in 0...1.
            return (stick, list, CGPoint(x: (x + 1) / 2, y: (y + 1) / 2))
        }
        .sorted { $0.stick < $1.stick }
    }

    /// Inline picker that lets the user switch THIS visualizer's
    /// template independently of the preset's slot menu. Sets the
    /// joystick mapping's `inputKind` via the host-supplied closure.
    private var templatePicker: some View {
        let currentKind: SlotInputKind = (slot < preset.joysticks.count)
            ? preset.joysticks[slot].inputKind : .auto
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
                .font(.caption)
                .foregroundStyle(.hint)
            if let onChangeControllerModel {
                controllerModelPicker(onChangeControllerModel)
            } else {
            Picker("Template", selection: Binding(
                get: { currentKind },
                set: { newKind in onChangeInputKind?(slot, newKind) }
            )) {
                Label("Auto-detect", systemImage: "wand.and.stars")
                    .tag(SlotInputKind.auto)
                Label("Screen", systemImage: "display")
                    .tag(SlotInputKind.screen)
                Label { Text("Controller") } icon: { MenuIcon(name: "gamecontroller") }
                    .tag(SlotInputKind.controller)
                Label("Keyboard (macOS)", systemImage: "keyboard")
                    .tag(SlotInputKind.keyboard)
                Label("Touchpad", systemImage: "rectangle.and.hand.point.up.left.fill")
                    .tag(SlotInputKind.touchpad)
                Label("Mouse & Trackpad", systemImage: "computermouse")
                    .tag(SlotInputKind.mouse)
                Label("MIDI Instrument", systemImage: "pianokeys")
                    .tag(SlotInputKind.midi)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .leading)
            .accessibilityLabel("Visualizer template")
            .accessibilityHint("Switches the Live Visualizer between controller, keyboard, touchpad, and mouse layouts")
            }
            Spacer(minLength: 0)
            if currentKind != .auto, onChangeControllerModel == nil {
                Button("Reset to auto") { onChangeInputKind?(slot, .auto) }
                    .buttonStyle(.solidSecondaryCompact)
                    .controlSize(.small)
                    .help("Use the binding-type majority to pick the template automatically.")
            }
        }
        .padding(.horizontal, 4)
        .spotlightAnchor(SpotlightID.templatePicker)
    }

    /// The one menu for this panel: Automatic, the other maps (Screen,
    /// Keyboard, Touchpad, Mouse, MIDI), then Connected and a menu per maker with the connected
    /// controller and every model by maker. Choosing a model sets the
    /// group's model, which the map draws when nothing is connected, and its
    /// button names, and shows the controller map.
    private func controllerModelPicker(_ change: @escaping (Int, ControllerModelID?) -> Void) -> some View {
        let group = slot < preset.joysticks.count ? preset.joysticks[slot] : nil
        let kind = group?.inputKind ?? .auto
        let chosen = group?.controllerModel.flatMap { ControllerLayoutCatalog.layout(ControllerModelID(rawValue: $0)) }
        let connected = ControllerLayoutResolver.match(service: controllerService, slot: deviceSlot)
        let showingController = (kind == .auto || kind == .controller) && !slotIsMacTapsOnly
            && (effectiveInputKind == .controller || effectiveInputKind == .auto)
        // The menu names what is drawn: a connected pad no layout knows is
        // drawn as the standard gamepad, whatever model the group is set to.
        let padHere = info != nil
        let maps: [(kind: SlotInputKind, name: String, icon: String)] = [
            (.screen, "Screen", "display"), (.keyboard, "Keyboard", "keyboard"),
            (.touchpad, "Touchpad", "rectangle.and.hand.point.up.left.fill"),
            (.mouse, "Mouse", "computermouse"), (.midi, "MIDI", "pianokeys"),
        ]
        // Off the controller map the title names the map drawn, chosen or
        // picked on Automatic from the rows: a keyboard preset said
        // "DualSense" over a keyboard drawing.
        let shownKind = kind != .auto ? kind : effectiveInputKind
        let title = !showingController ? (maps.first { $0.kind == shownKind }?.name ?? "Automatic")
            : (resolvedLayout?.layout.displayName ?? connected?.displayName
                ?? (padHere ? info?.name : nil) ?? chosen?.displayName ?? "Automatic")
        // A model choice also brings the controller map back.
        func pick(_ id: ControllerModelID?) {
            change(slot, id)
            if kind != .auto && kind != .controller { onChangeInputKind?(slot, .controller) }
        }
        return Menu {
            Button {
                change(slot, nil)
                if kind != .auto { onChangeInputKind?(slot, .auto) }
            } label: {
                if kind == .auto && group?.controllerModel == nil {
                    Label("Automatic", systemImage: "checkmark")
                } else {
                    Label("Automatic", systemImage: "wand.and.stars")
                }
            }
            ForEach(maps, id: \.name) { map in
                Button { onChangeInputKind?(slot, map.kind) } label: {
                    Label(map.name, systemImage: kind == map.kind ? "checkmark" : map.icon)
                }
            }
            Divider()
            // The connected controllers, then each maker as its own submenu
            // at the top level: one level down instead of two, so a model
            // is two moves away.
            let pads = connectedPadNames
            if !pads.isEmpty, let onChangeDevice {
                // The group's device, picked here as in the editor's
                // device menu: the group then reads that pad, drawn as
                // itself.
                Section("Connected") {
                    ForEach(pads, id: \.self) { name in
                        let padSlot = controllerService.slot(forDeviceNamed: name, preferring: slot)
                        let padLayout = padSlot.flatMap { ControllerLayoutResolver.match(service: controllerService, slot: $0) }
                        let reading = info != nil && padSlot == deviceSlot
                            && (group?.controllerModel == nil || chosen?.id == padLayout?.id)
                            && resolvedLayout?.layout.id == padLayout?.id
                        Button {
                            // Drawn as itself from now on, whatever the
                            // preset was made for.
                            change(slot, padLayout?.id)
                            onChangeDevice(slot, name)
                        } label: {
                            if reading { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                }
            } else if let connected {
                Section("Connected") {
                    Button("\(connected.displayName)") {
                        // With the variant drawn now, so it stays when unplugged.
                        if let r = resolvedLayout, r.layout.id == connected.id, let v = r.variant {
                            pick(ControllerModelID("\(connected.id.rawValue).\(v)"))
                        } else {
                            pick(connected.id)
                        }
                    }
                }
            }
            ForEach(ControllerLayoutCatalog.byMaker, id: \.maker) { section in
                Menu {
                    ForEach(section.layouts) { layout in
                        if layout.variants.count > 1 {
                            let stored = group?.controllerModel.map(ControllerModelID.init(rawValue:))
                            Menu {
                                ForEach(layout.variants, id: \.id) { v in
                                    let isChosen = stored?.base == layout.id && (stored?.variant ?? layout.defaultVariant) == v.id
                                    Button {
                                        pick(ControllerModelID("\(layout.id.rawValue).\(v.id)"))
                                    } label: {
                                        if isChosen { Label(v.displayName, systemImage: "checkmark") } else { Text(v.displayName) }
                                    }
                                }
                            } label: {
                                if chosen?.id == layout.id { Label(layout.displayName, systemImage: "checkmark") } else { Text(layout.displayName) }
                            }
                        } else {
                            Button {
                                pick(layout.id)
                            } label: {
                                if chosen?.id == layout.id { Label(layout.displayName, systemImage: "checkmark") } else { Text(layout.displayName) }
                            }
                        }
                    }
                } label: {
                    if chosen?.maker == section.maker { Label(section.maker.title, systemImage: "checkmark") } else { Text(section.maker.title) }
                }
            }
        } label: {
            Label(title, systemImage: showingController ? "gamecontroller" : (maps.first { $0.kind == shownKind }?.icon ?? "gamecontroller"))
                .font(.callout)
        }
        .fixedSize()
        .help(connected != nil
              ? "Pick a connected controller for this group to read, or a model from its maker's menu to draw it as. Automatic draws the connected controller as itself."
              : "What this panel shows: the controller this group is set up for, or a screen, keyboard, touchpad, mouse or MIDI map.")
        .accessibilityLabel("Visualizer map")
        .accessibilityValue(title)
    }

    /// Every connected controller by the name the editor's device menu
    /// gives it, two of one name numbered ("Xbox Wireless Controller 2").
    private var connectedPadNames: [String] {
        let gc = controllerService.connectedControllers.map { $0.vendorName ?? $0.productCategory }
        let raw = controllerService.rawHIDGamepadSlots.sorted { $0.key < $1.key }.map(\.value.displayName)
        var names = JoystickGroupView.numberedNames(gc + raw)
        if controllerService.steamControllerSlot != nil { names.append("Steam Controller") }
        return names
    }

    // The controller diagram is drawn whenever we are in the controller
    // template: either a physical controller is attached, or the slot has
    // bindings to visualize. Without this, selecting Controller with nothing
    // plugged in rendered a blank panel.
    private var showDiagram: Bool { info != nil || slotHasAnyBinding }

    private var slotHasAnyBinding: Bool {
        guard slot < preset.joysticks.count else { return false }
        return !preset.joysticks[slot].bindings.isEmpty
    }

    @ViewBuilder
    private var emptyVisualizerPlaceholder: some View {
        VStack(spacing: 8) {
            ControllerGlyph(height: 26)
                .foregroundStyle(.hint)
            Text("No controller connected for slot \(slot) and no bindings to visualize.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// HID keycodes the slot has at least one binding for. Computed
    /// outside the @ViewBuilder body so the type-checker doesn't have
    /// to thread control flow through the keyboard layout closure.
    private var boundKeyCodesForSlot: Set<Int> {
        guard slot < preset.joysticks.count else { return [] }
        var out: Set<Int> = []
        for b in preset.joysticks[slot].bindings where b.input.type == .extKey {
            out.insert(b.input.index)
        }
        return out
    }

    /// HID keycodes currently held down on any external keyboard.
    /// Walks `rawActiveInputs` (entries like "ekb <code> <dev>") and
    /// pulls the HID code out. O(N) over the active set every render.
    private var pressedKeyCodes: Set<Int> {
        var out: Set<Int> = []
        for entry in externalInput.rawActiveInputs
            where entry.hasPrefix("ekb ") {
            let parts = entry.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                out.insert(code)
            }
        }
        return out
    }

    /// Set of mouse "kinds" the slot has at least one binding for.
    /// Buttons turn into "btn<N>"; scroll axes into "scrollUp" /
    /// "scrollDown" depending on `axisDirection`; motion axes into
    /// "move". Matches the keys MouseDiagramView highlights.
    private var boundMouseKinds: Set<String> {
        guard slot < preset.joysticks.count else { return [] }
        var out: Set<String> = []
        for b in preset.joysticks[slot].bindings where b.input.type == .extMouse {
            out.insert(Self.mouseKind(b.input))
        }
        return out
    }

    /// The mouse diagram's name for a mouse input: "btn<N>", "move",
    /// "scrollUp" and so on.
    private static func mouseKind(_ input: InputEvent) -> String {
        switch input.extMouseKind ?? .button {
        case .button: return "btn\(input.index)"
        case .moveX, .moveY: return "move"
        case .scrollY: return input.axisDirection == .negative ? "scrollDown" : "scrollUp"
        case .scrollX: return input.axisDirection == .negative ? "scrollLeft" : "scrollRight"
        case .pressure: return "pressure"
        case .deepPress: return "deepPress"
        case .doubleClick: return "doubleClick"
        case .scrollGesture: return "scrollGesture"
        }
    }

    /// The slot's own mouse inputs of these kinds, exactly as its rows hold
    /// them (a row can name one mouse), for the inspector to match.
    private func mouseInspectEvents(_ kinds: Set<String>) -> [InputEvent] {
        guard slot < preset.joysticks.count else { return [] }
        return preset.joysticks[slot].bindings
            .filter { $0.input.type == .extMouse && kinds.contains(Self.mouseKind($0.input)) }
            .map(\.input)
    }

    /// The same for keys on the Mac's keyboard.
    private func keyInspectEvents(_ codes: [Int]) -> [InputEvent] {
        guard slot < preset.joysticks.count else { return [] }
        return preset.joysticks[slot].bindings
            .filter { $0.input.type == .extKey && codes.contains($0.input.index) }
            .map(\.input)
    }

    /// Currently-pressed mouse buttons from `rawActiveInputs`.
    private var pressedMouseButtons: Set<Int> {
        var out: Set<Int> = []
        for entry in externalInput.rawActiveInputs
            where entry.hasPrefix("ems button ") {
            let parts = entry.split(separator: " ")
            if parts.count >= 3, let n = Int(parts[2]) {
                out.insert(n)
            }
        }
        return out
    }

    /// Movement, scroll, and Force Touch happening right now, as the kinds
    /// the mouse diagram lights.
    private var activeMouseKinds: Set<String> {
        var out: Set<String> = []
        for entry in externalInput.rawActiveInputs where entry.hasPrefix("ems ") {
            let parts = entry.split(separator: " ")
            guard parts.count >= 4 else { continue }
            switch parts[1] {
            case "moveX", "moveY": out.insert("move")
            case "scrollY": out.insert(parts[3] == "-" ? "scrollDown" : "scrollUp")
            case "scrollX": out.insert(parts[3] == "-" ? "scrollLeft" : "scrollRight")
            case "pressure": out.insert("pressure")
            case "deepPress": out.insert("deepPress")
            case "doubleClick": out.insert("doubleClick")
            case "scrollGesture": out.insert("scrollGesture")
            default: break
            }
        }
        return out
    }

    /// Shown on the keyboard and mouse templates until the app may listen.
    @ViewBuilder
    private var accessibilityNeededNote: some View {
        if !accessibility.isTrusted {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Live keys and clicks need the Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The same request as every other Accessibility button: it
                // adds InputConfig to the list and watches for the grant.
                Button("Open System Settings") {
                    AccessibilityPermissionService.shared.requestAccess()
                }
                .buttonStyle(.solidSecondaryCompact)
                .controlSize(.small)
            }
        }
    }

    /// Keyboard-mode visualizer. Renders the real macOS keyboard layout
    /// (six rows + optional numpad). Bound keys appear in full
    /// contrast; unbound keys dim. Pressed keys flash green.
    @ViewBuilder
    private var keyboardLayout: some View {
        let bound = boundKeyCodesForSlot
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Keyboard layout", systemImage: "keyboard")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(bound.count) key\(bound.count == 1 ? "" : "s") bound")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            accessibilityNeededNote
            ExternalInputObserver {
                // A bound key opens its rows, as a button on the controller does.
                KeyboardDiagramView(boundKeyCodes: bound, pressedKeyCodes: pressedKeyCodes,
                                    inspect: { codes, name, tile in
                                        AnyView(inspectable(label: name, key: "key-\(codes.map(String.init).joined(separator: ","))",
                                                            events: keyInspectEvents(codes), draggable: false) { tile })
                                    })
            }
            if bound.isEmpty {
                Text("No keyboard keys bound for this slot. Press any key to see it light here; scan a key in the editor to bind it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    /// Mouse and trackpad visualizer: the Mac's pointer device, whatever
    /// it is. Buttons, scroll in four directions, motion, and the
    /// trackpad's Force Touch, all live.
    @ViewBuilder
    private var mouseLayout: some View {
        let boundKinds = boundMouseKinds
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Mouse and trackpad", systemImage: "computermouse")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(boundKinds.count) input\(boundKinds.count == 1 ? "" : "s") bound")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            accessibilityNeededNote
            ExternalInputObserver {
                MouseDiagramView(pressedButtons: pressedMouseButtons,
                                 activeKinds: activeMouseKinds,
                                 boundKinds: boundKinds,
                                 pressure: externalInput.trackpadPressure,
                                 pressureStage: externalInput.trackpadPressureStage,
                                 scrollGesture: externalInput.scrollGesture,
                                 // A bound part opens its rows, as a button
                                 // on the controller does.
                                 inspect: { kinds, name, part in
                                     AnyView(inspectable(label: name, key: "mouse-\(name)",
                                                         events: mouseInspectEvents(kinds), draggable: false) { part })
                                 })
            }
            Text("Force Touch is read only while InputConfig is the front window; everything else works from any app.")
                .font(.caption2)
                .foregroundStyle(.hint)
                .fixedSize(horizontal: false, vertical: true)
            if boundKinds.isEmpty {
                Text("No mouse or trackpad inputs bound for this slot. Click, scroll, or move to see it light here; scan a button in the editor to bind it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    /// Touchpad-template visualizer. Shows the controller's touchpad
    /// surface with user-defined regions overlaid, live finger trails,
    /// the touchpad-button press state, and a binding summary. Sits
    /// between the keyboard and mouse layouts in the template picker
    /// for users who primarily map the touchpad.
    @ViewBuilder
    private var touchpadLayout: some View {
        let touchpadBindings = boundTouchpadInputs
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(touchpadSurfaceName, systemImage: "rectangle.and.hand.point.up.left.fill")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(touchpadBindings) input\(touchpadBindings == 1 ? "" : "s") bound")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Reuse the visualizer's existing TouchpadWidget. It draws
            // 220 points wide in the real shape of the surface: a wide
            // letterbox for a controller pad, close to 3:2 for the Mac's
            // own trackpad.
            // Centered in the layout column with a scale-up so it
            // reads as the primary surface of the template rather
            // than a small accessory like it does on the controller
            // layout. Wrapped in a transparent container the same
            // width as the parent so SwiftUI doesn't squeeze it into
            // an awkward leading-aligned chunk.
            // This template is the touchpad and nothing else. Screen
            // regions have their own template, so nothing about the screen
            // is ever said here; a preset with no touchpad rows still gets
            // the pad, so there is something to scan into.
            HStack {
                Spacer(minLength: 0)
                touchpadSurface(pressed: (state.buttons[13] ?? 0) > 0.5)
                    .scaleEffect(1.5, anchor: .center)
                    // A scaleEffect leaves the layout box at the
                    // unscaled size, so a quarter of each dimension is
                    // added back by hand and the surrounding HStack
                    // measures what is actually visible. Derived from
                    // the pad's real height, which changes with the
                    // surface rather than always being 70.
                    .padding(.horizontal, 55)
                    .padding(.vertical, touchpadPadHeight / 4)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            if touchpadBindings == 0 {
                Text("No touchpad inputs bound for this slot. In the editor, pick Touchpad from the input type menu, or Scan a tap or a zone, or pick \"Apply default 1 to 16\" from the Touchpad Setup sheet for a starter grid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    /// The surface the touchpad template is showing. The controller's own
    /// pad and the Mac's trackpad are different inputs: the first is read
    /// from the controller, the second through the Mac's own pointer, and
    /// a preset can use either.
    private var touchpadSurfaceName: String {
        if capabilities.touchpad, let name = info?.name { return "\(name) touchpad" }
        if info != nil { return "Controller touchpad" }
        return "Mac trackpad"
    }

    /// The touchpad drawing, clickable as a whole (its fingers, press, taps
    /// and every zone) and zone by zone: a click on a zone lists that
    /// zone's rows. The zone targets sit beside the pad's button, not in
    /// it, so a click on a zone is the zone's alone. Both offer Touchpad
    /// Setup, where zones are drawn.
    @ViewBuilder
    private func touchpadSurface(pressed: Bool) -> some View {
        ZStack {
            inspectable(label: "Touchpad", events: touchpadInspectEvents, editor: .touchpadSetup) {
                TouchpadWidget(pressed: pressed,
                               presetRegions: preset.touchpadRegions,
                               surfaceAspect: touchpadSurfaceAspect)
            }
            // Not while rearranging: the pad is then dragged, zones and all.
            if !editMode && !preset.touchpadRegions.isEmpty {
                touchpadZoneTargets
                    .offset(dragOffsets["Touchpad"] ?? .zero)
            }
        }
    }

    /// One invisible click target over each zone the pad draws, in the
    /// same place TouchpadWidget draws it.
    private var touchpadZoneTargets: some View {
        let w: CGFloat = 220
        let h = touchpadPadHeight
        return ZStack(alignment: .topLeading) {
            ForEach(preset.touchpadRegions) { region in
                let rect = CGRect(x: CGFloat(region.minX) * w, y: CGFloat(region.minY) * h,
                                  width: CGFloat(region.maxX - region.minX) * w,
                                  height: CGFloat(region.maxY - region.minY) * h)
                inspectable(label: region.name, key: "zone-\(region.id)",
                            events: [InputEvent.touchpadRegion(region.id)],
                            draggable: false, editor: .touchpadSetup) {
                    Color.clear
                        .frame(width: max(8, rect.width), height: max(8, rect.height))
                        .contentShape(Rectangle())
                        .accessibilityLabel("\(region.name) zone")
                }
                .help("\(region.name). Click to see its rows.")
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: w, height: h)
    }

    /// Count of touchpad-type bindings on this slot (touchpad axes,
    /// regions, gestures). Drives the "N inputs bound" summary in the
    /// touchpad layout header.
    private var boundTouchpadInputs: Int {
        guard slot < preset.joysticks.count else { return 0 }
        return preset.joysticks[slot].bindings.reduce(0) { acc, b in
            switch b.input.type {
            case .touchpad, .touchpadRegion, .touchpadGesture: return acc + 1
            default: return acc
            }
        }
    }

    /// What the device in this slot actually reports, read through the same
    /// system the editor's automatic layout uses. The visualizer draws from
    /// this: a pad with no D-pad gets no D-pad, a controller with no gyro
    /// gets no motion meter, an Access Controller gets its one stick.
    /// The slot this panel reads: the device picked from the group's menu
    /// when it is connected, else the panel's own slot.
    private var deviceSlot: Int {
        guard slot < preset.joysticks.count else { return slot }
        return controllerService.effectiveSlots(for: preset.joysticks)[slot] ?? slot
    }

    private var capabilities: ControllerScaffold.DeviceCapabilities {
        ControllerScaffold.capabilities(service: controllerService, slot: deviceSlot,
                                        inputKind: slot < preset.joysticks.count
                                            ? preset.joysticks[slot].inputKind : .auto,
                                        purpose: .mirror, presetFamily: preset.buttonFamily)
    }

    /// The names printed on the face, shoulder and menu buttons, from the
    /// family the slot is named in (the same one the editor rows use, see
    /// ButtonNames.resolve): Cross / Circle / Square / Triangle on
    /// PlayStation, B / A / Y / X on a Switch pad, whose buttons sit in the
    /// opposite places, A / B / X / Y on the rest. The Face button names
    /// setting picks the letters only for a pad of no known family (most
    /// 8BitDo pads report themselves as Xbox pads); Positions puts compass
    /// points on every pad.
    private func brandLabels(_ caps: ControllerScaffold.DeviceCapabilities)
        -> (face: [Int: String], menu: [Int: String], tint: [Int: Color], shoulder: [Int: String]) {
        let choice = FaceLetters(rawValue: faceLettersRaw) ?? .automatic
        let family = caps.family
        let shoulder: [Int: String] = Dictionary(uniqueKeysWithValues: [4, 5, 6, 7].map {
            ($0, ButtonNames.short($0, family: family, model: caps.model) ?? "")
        })
        let menu: [Int: String] = Dictionary(uniqueKeysWithValues: [8, 9, 10].map {
            ($0, ButtonNames.short($0, family: family, model: caps.model) ?? "")
        })
        let nintendoFace: [Int: String] = [0: "B", 1: "A", 2: "Y", 3: "X"]
        let xboxFace: [Int: String] = [0: "A", 1: "B", 2: "X", 3: "Y"]
        let plain: [Int: Color] = [0: .secondary, 1: .secondary, 2: .secondary, 3: .secondary]
        // Sony's glyphs in Sony's colors: cross blue, circle red, square
        // pink, triangle green.
        let psFace: [Int: String] = [0: "\u{2715}", 1: "\u{25CB}", 2: "\u{25A1}", 3: "\u{25B3}"]
        let psTint: [Int: Color] = [0: Color(red: 0.45, green: 0.65, blue: 1.0), 1: .red, 2: .pink, 3: .green]
        if choice == .positions {
            // Compass points on every pad, PlayStation included: S on the
            // bottom, then E, W, N. Plain, since no pad prints them in color.
            let positions: [Int: String] = family == .gameCube
                ? [0: "S", 1: "W", 2: "E", 3: "N"] : [0: "S", 1: "E", 2: "W", 3: "N"]
            return (positions, menu, plain, shoulder)
        }
        switch family {
        case .playstation?:
            return (psFace, menu, psTint, shoulder)
        case .nintendo?:
            return (nintendoFace, menu, plain, shoulder)
        case .xbox?:
            // Many 8BitDo pads, printed B on the bottom, report themselves
            // as Xbox pads, so the setting picks the letters here too.
            if choice == .playstation { return (psFace, menu, psTint, shoulder) }
            if choice == .nintendo { return (nintendoFace, menu, plain, shoulder) }
            return (xboxFace, menu, letterTint(false), shoulder)
        case .gameCube?:
            // The big green A and the red B; X and Y are plain.
            return (xboxFace, menu, [0: .green, 1: .red, 2: .secondary, 3: .secondary], shoulder)
        case .stadia?, .steamController?, .steamController2026?:
            // Printed in one color.
            return (xboxFace, menu, plain, shoulder)
        case .automatic?, .positions?, nil:
            if choice == .playstation { return (psFace, menu, psTint, shoulder) }
            let nintendo = FaceLetters.nintendo(for: info?.brand ?? .unknown, choice: choice)
            return (nintendo ? nintendoFace : xboxFace, menu, letterTint(nintendo), shoulder)
        }
    }

    /// A row's name in the inspector, with the family and model names of
    /// the group it belongs to, as the editor shows it.
    private func inspectorName(_ match: BindingMatch) -> String {
        let slots = controllerService.effectiveSlots(for: preset.joysticks)
        let naming = controllerService.naming(forSlot: slots[match.joystickIndex] ?? match.joystickIndex,
                                              presetFamily: preset.buttonFamily)
        let input = match.binding.input
        // A stick or trackpad direction in words: "Left stick right".
        // A pad of no family still has sticks where the map draws them.
        let axisFamily = naming.family ?? (input.index < 6 && !capabilities.sticks.isEmpty ? .automatic : nil)
        if input.type == .axis, let name = ButtonNames.axisName(input.index, family: axisFamily) {
            let positive = input.axisDirection != .negative
            if name.hasSuffix(" X") { return String(name.dropLast(2)) + (positive ? " right" : " left") }
            if name.hasSuffix(" Y") { return String(name.dropLast(2)) + (positive ? " down" : " up") }
            return name
        }
        if input.type == .hat, let dir = input.hatDirection { return "D-pad " + dir.displayName.lowercased() }
        return ButtonNames.inputName(input, family: naming.family, model: naming.model)
    }

    /// The button that presses a trackpad drawn on these axes, or nil.
    private func trackpadPress(axisX: Int, steam2015: Bool) -> Int? {
        if steam2015 { return axisX == 6 ? SteamControllerButton.leftPadClick.rawValue : nil }
        switch axisX {
        case 6: return 18   // 2026 Steam Controller, left trackpad click
        case 8: return 19   // right trackpad click
        default: return nil
        }
    }

    /// Xbox letter colors go only with the Xbox letters they belong to;
    /// Nintendo-lettered pads get plain letters.
    private func letterTint(_ nintendoLetters: Bool) -> [Int: Color] {
        nintendoLetters
            ? [0: .secondary, 1: .secondary, 2: .secondary, 3: .secondary]
            : [0: .green, 1: .red, 2: .blue, 3: .yellow]
    }

    // MARK: - Controller drawing

    /// The controller model drawn for this slot: the connected pad, else the
    /// group's chosen model, else one inferred from the preset.
    private var resolvedLayout: ResolvedLayout? {
        ControllerLayoutResolver.resolve(service: controllerService, slot: deviceSlot,
                                         group: slot < preset.joysticks.count ? preset.joysticks[slot] : nil,
                                         preset: preset)
    }

    /// The real controller, drawn from its layout.
    @ViewBuilder
    private func canvas(_ resolved: ResolvedLayout) -> some View {
        // The inputs as this pad's read path gives them.
        let layout = resolved.layout.reading(on: resolved.readPath)
        let naming = controllerService.naming(forSlot: deviceSlot, presetFamily: preset.buttonFamily)
        let family = naming.family ?? layout.family
        // The drawn model's own names when they fit: nothing pins another
        // family, or the pinned family is the model's own.
        let ownNames = naming.family == nil || naming.family == layout.family || layout.family == nil
        let model = ownNames ? resolved.layout.modelNames : naming.model
        // Legends and names describe the physical control, so they come from
        // its standard inputs, not the index a read path moved it to (an
        // 8BitDo Lite read from its descriptor sends Y as btn 4).
        let physical: (PlacedControl) -> PlacedControl = { c in resolved.layout.control(c.id) ?? c }
        let choice = FaceLetters(rawValue: faceLettersRaw) ?? .automatic
        let st = state
        // Inputs a control owns, plus the ones the layout says have no
        // place on the body (a mode bit), are not "also reported".
        // Only copies and state bits: a function a profile gave a socket is
        // a press of its own and is listed.
        let declared = layout.offBody.filter(\.copy).compactMap { InputEvent.parse($0.serialized) }.filter { $0.type == .button }.map(\.index)
        let owned = Set(layout.controls.flatMap(\.inputs.allButtons) + declared)
        let stray = st.buttons.filter { $0.value > 0.5 && !owned.contains($0.key) }.keys.sorted()
        // A Sony pad's fingers come from the touch service, by the drawn
        // model, whatever names its buttons take; only a pad that reports a
        // touchpad and feeds the service (an arcade stick drawn as a
        // PlayStation pad must not show a DualSense's fingers).
        let source = controllerService.touchpadSourceSlot
        let sonyTouch = layout.family == .playstation && resolved.readPath == .gameController
            && info?.hasTouchpad == true && (source == nil || source == deviceSlot)
        // A Steam pad's zones light from the one pad feeding the Steam surface.
        let steamSource = controllerService.touchpadSteamSourceSlot
        let steamTouch = layout.family?.isSteam == true && controllerService.isSteamSlot(deviceSlot)
            && (steamSource == nil || steamSource == deviceSlot)
        // On a DualSense or DualSense Edge the gyro ball sits in the drawing,
        // between L2 and R2, where it is easy to see and stays in view with
        // the rest; on every other pad it stays under the drawing.
        let gyroOnTop = info?.supportsMotion == true && [.dualSense, .dualSenseEdge].contains(layout.id)
        let showsLightBar = info?.hasLight == true || layout.controls.contains(where: { $0.id.hasPrefix("lightbar") })
        VStack(spacing: 8) {
            // The preset's light bar color is set here, as before the canvas:
            // for a pad with a light, or a drawing of one with nothing plugged in.
            if showsLightBar {
                lightBarStripWidget.frame(maxWidth: 640)
            }
            ControllerCanvas(
                layout: layout,
                variant: resolved.variant,
                state: st,
                legend: { CanvasLegend.legend(for: physical($0), in: layout, family: family, model: model, choice: choice) },
                ownLegend: { CanvasLegend.legend(for: physical($0), in: layout, family: layout.family,
                                                 model: resolved.layout.modelNames, choice: .automatic) },
                caption: { boundCaption(for: $0, layout: layout) },
                touchPoints: { surface in
                    guard surface == 0, sonyTouch else { return [] }
                    let tp = TouchpadService.shared
                    let size = tp.nominalSurfaceSize
                    return (0..<2).compactMap { f in
                        tp.currentPosition(finger: f).map {
                            CGPoint(x: CGFloat($0.x) / CGFloat(max(1, size.width)), y: CGFloat($0.y) / CGFloat(max(1, size.height)))
                        }
                    }
                },
                // Zones only on a surface whose fingers reach the touch service.
                zones: sonyTouch || steamTouch ? preset.touchpadRegions : [],
                zoneOn: { id in
                    // A Steam pad's right trackpad has its own instance.
                    (layout.family?.isSteam == true ? TouchpadService.steamRight : TouchpadService.shared).isRegionPressed(id)
                },
                name: { canvasName(physical($0), layout: layout, family: family, model: model, choice: choice) },
                livePaused: !appIsActive,
                // The preset's color, else the one the pad is showing now.
                lightColor: lightBarTint ?? controllerService.shownLightColor(slot: deviceSlot).map {
                    Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255)
                },
                // The orange line on a trigger or pedal no row in this group
                // reads: the engine's default. A row's own comes with its
                // deadzone below.
                threshold: { _ in 0.25 },
                deadzone: { canvasDeadzone($0, layout: layout) },
                between: gyroOnTop ? ("l2", "r2", AnyView(motionWidgetIfAvailable)) : nil,
                inspect: { control, view in
                    let name = canvasName(physical(control), layout: layout, family: family, model: model, choice: choice)
                    // A touch surface's zones are drawn in Touchpad Setup.
                    let editor: VisualizerRegionEditor? = layout.surface(forControl: control.id) != nil ? .touchpadSetup : nil
                    return AnyView(inspectable(label: name, key: "canvas-\(control.id)",
                                               events: canvasEvents(control, layout: layout), draggable: false,
                                               note: canvasNote(control), editor: editor) { view })
                })
                .frame(maxWidth: 640)
            if info?.supportsMotion == true {
                if !gyroOnTop { motionWidgetIfAvailable }
                motionDeadzoneMeters(st)
            }
            if let note = resolved.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            // What this model does not send to a Mac, so a dark control is
            // not taken for a fault.
            switch resolved.layout.readability {
            case .partial(let why), .notReadable(let why):
                Text(why).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            case .full:
                EmptyView()
            }
            if !stray.isEmpty {
                // Strays are numbered by the read path, so the path's names.
                Text("Also reported: " + stray.map { ButtonNames.label($0, family: family, model: naming.family == nil ? layout.modelNames : naming.model) }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// What a control's inspector lists: its own inputs, and for a touch
    /// surface every finger, zone and gesture row it can carry.
    private func canvasEvents(_ c: PlacedControl, layout: ControllerLayout) -> [InputEvent] {
        var events = c.inputs.inspectEvents()
        guard let spec = layout.surface(forControl: c.id) else { return events }
        func onSurface(_ e: InputEvent) -> InputEvent {
            var e = e
            if spec.surface == 1 { e.touchpadSurface = 1 }
            return e
        }
        for finger in 0..<max(1, min(2, spec.maxFingers)) {
            for axis in TouchpadAxis.allCases {
                for direction in AxisDirection.allCases {
                    events.append(onSurface(.touchpad(finger: finger, axis: axis, direction: direction)))
                }
            }
        }
        // Zones are drawn on the first surface only.
        if spec.surface == 0 { events += preset.touchpadRegions.map { InputEvent.touchpadRegion($0.id) } }
        events += TouchpadGestureKind.allCases.map { onSurface(.touchpadGesture($0)) }
        return events
    }

    /// The line under a control's inspector title: when it is read only in
    /// some setups, why; else the layout's note on it.
    private func canvasNote(_ c: PlacedControl) -> String? {
        if case .conditional(let why) = c.readable { return why }
        return c.note
    }

    /// A control's name for its inspector title and VoiceOver.
    private func canvasName(_ c: PlacedControl, layout: ControllerLayout, family: FaceLetters?,
                            model: ButtonNames.ModelNames, choice: FaceLetters) -> String {
        if let spec = layout.surface(forControl: c.id) { return spec.name }
        if let name = c.name { return name }
        if let dir = c.inputs.hatDirection { return "D-pad \(dir.displayName.lowercased())" }
        switch c.kind {
        case .stick:
            if let x = c.inputs.axes.first?.index, let n = ButtonNames.axisName(x, family: family ?? .automatic),
               n.hasSuffix(" X") { return String(n.dropLast(2)) }
            return "Stick"
        case .dpad: return "D-pad"
        case .trigger:
            // The analog trigger, not its digital copy's "(digital)" name.
            if let a = c.inputs.axes.first?.index, let n = ButtonNames.axisName(a, family: family ?? .automatic) { return n }
            if let d = c.inputs.digitalCopy, let short = ButtonNames.short(d, family: family, model: model) { return short }
            return c.printed ?? "Trigger"
        default:
            if let b = c.inputs.buttons.first {
                // The family's full name where it has one ("Left Fn (Edge)"
                // for a button printed "Fn"); the printed legend otherwise.
                let label = ButtonNames.label(b, family: family, model: model, choice: choice)
                if let printed = c.printed, label.hasPrefix("Button ") { return printed }
                return label
            }
            if let printed = c.printed { return printed }
            // The id in words, never the raw id.
            return CanvasLegend.words(c.id)
        }
    }

    /// The function a control is bound to in this group, for its caption:
    /// the row's note, else its outputs.
    private func boundCaption(for c: PlacedControl, layout: ControllerLayout) -> String? {
        guard slot < preset.joysticks.count else { return nil }
        let keys = Set(canvasEvents(c, layout: layout).map(\.serialized))
        let rows = preset.joysticks[slot].bindings.filter { keys.contains($0.input.serialized) }
        guard let row = rows.first else { return nil }
        let note = (row.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = note.isEmpty ? row.outputs.map(\.displayName).joined(separator: " + ") : note
        return rows.count > 1 ? text + " +\(rows.count - 1)" : text
    }

    @ViewBuilder
    private var controllerWidgets: some View {
        var caps = capabilities
        let labels = brandLabels(caps)
        // Where each standard button sits on this device. The Steam
        // Controller numbers its own (its 0 is RT digital, its A is 7), so
        // the map drew its buttons under the wrong names. -1: not there.
        // The 2015 model's own numbering; the 2026 model reads the standard
        // indices, though it shares the brand.
        // Also a 2015 preset drawn with no Steam Controller in its slot: its
        // rows are on that numbering.
        let isSteam = caps.family == .steamController
        let std: (Int) -> Int = { standard in
            isSteam ? (SteamControllerButton.index(forStandardButton: standard) ?? -1) : standard
        }
        let has: (Int) -> Bool = { standard in caps.buttons.contains(where: { $0.index == std(standard) }) }
        // Safety net: anything the controller is actually sending is drawn,
        // whatever the capability read said. A control that fires but is
        // not on screen is the worst possible outcome here.
        let _ = {
            let st = state
            if st.hats[0] != nil { caps.dpad = true }
            if (st.axes[4] ?? 0) != 0 || (st.axes[5] ?? 0) != 0 { caps.triggers = true }
            // Not the Steam Controller's "left pad and stick both in use"
            // bit, which is a state, not a button, and showed as "Button 22".
            for index in st.buttons.keys where !caps.buttons.contains(where: { $0.index == index })
                && !(isSteam && index == SteamControllerButton.stickActive.rawValue) {
                caps.buttons.append((index, "Button \(index)"))
            }
            if caps.sticks.isEmpty, st.axes[0] != nil || st.axes[1] != nil {
                caps.sticks = [("Left stick", 0, 1, "Left stick")]
            }
        }()
        VStack(spacing: 14) {
            // Light-bar strip - rendered for any controller that has one
            // (DualSense, DualShock 4). Sits at the top like the real
            // DualSense light bar that wraps over the touchpad.
            if info?.hasLight == true {
                lightBarStripWidget
            }

            // Top row: bumpers + triggers. v1.1 behavior: always shown
            // when a controller is connected, regardless of which inputs
            // the preset currently binds. The visualizer is a HARDWARE
            // mirror first, binding inspector second; hiding unbound
            // widgets made connected controllers look broken when a
            // preset only mapped a few inputs.
            if showDiagram {
                HStack(alignment: .center, spacing: 16) {
                    VStack(spacing: 8) {
                        if caps.triggers {
                            inspectable(label: labels.shoulder[6] ?? "LT", key: "LT", events: [.axis(4, direction: .positive)]) {
                                TriggerWidget(label: labels.shoulder[6] ?? "LT", value: state.axes[4] ?? 0,
                                              threshold: thresholdForAxis(4, dir: .positive),
                                              tint: .blue)
                            }
                        }
                        if has(4) {
                            inspectable(label: labels.shoulder[4] ?? "LB", key: "LB", events: [.button(std(4))]) {
                                ShoulderWidget(label: labels.shoulder[4] ?? "LB", pressed: (state.buttons[std(4)] ?? 0) > 0.5)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            ForEach([8, 10, 9], id: \.self) { index in
                                if has(index) {
                                    menuPill(label: labels.menu[index] ?? "Menu", index: std(index), key: "menu-\(index)")
                                }
                            }
                        }
                        if caps.gyro { motionWidgetIfAvailable }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        if caps.triggers {
                            inspectable(label: labels.shoulder[7] ?? "RT", key: "RT", events: [.axis(5, direction: .positive)]) {
                                TriggerWidget(label: labels.shoulder[7] ?? "RT", value: state.axes[5] ?? 0,
                                              threshold: thresholdForAxis(5, dir: .positive),
                                              tint: .red)
                            }
                        }
                        if has(5) {
                            inspectable(label: labels.shoulder[5] ?? "RB", key: "RB", events: [.button(std(5))]) {
                                ShoulderWidget(label: labels.shoulder[5] ?? "RB", pressed: (state.buttons[std(5)] ?? 0) > 0.5)
                            }
                        }
                    }
                }
            }

            // Middle row: D-pad on the left, both sticks side by side in
            // the middle, the four face buttons on the right, the way the
            // controls sit on the pad itself. One row instead of two, so
            // the map is shorter and the sticks are not off in a corner.
            if showDiagram {
                HStack(alignment: .center) {
                    if caps.dpad {
                        inspectable(label: "D-pad", events: [
                            .hat(0, direction: .up), .hat(0, direction: .right),
                            .hat(0, direction: .down), .hat(0, direction: .left)
                        ] + (isSteam ? (8...11).map { InputEvent.button($0) } : [])) {
                            DPadWidget(hat: state.hats[0] ?? (0, 0))
                        }
                    }
                    Spacer(minLength: 0)
                    if caps.sticks.count >= 2 {
                        HStack(spacing: 18) {
                            inspectable(label: caps.sticks[0].label, key: "Left stick", events: [
                                .axis(0, direction: .positive), .axis(0, direction: .negative),
                                .axis(1, direction: .positive), .axis(1, direction: .negative),
                                .button(std(11))
                            ]) {
                                StickWidget(label: caps.sticks[0].label,
                                            x: state.axes[0] ?? 0,
                                            y: state.axes[1] ?? 0,
                                            pressed: (state.buttons[std(11)] ?? 0) > 0.5)
                            }
                            // The 2015 Steam Controller's right "stick" is its
                            // right trackpad, pressed on its own button.
                            let rightPress = isSteam ? SteamControllerButton.rightPadClick.rawValue : 12
                            inspectable(label: caps.sticks[1].label, key: "Right stick", events: [
                                .axis(2, direction: .positive), .axis(2, direction: .negative),
                                .axis(3, direction: .positive), .axis(3, direction: .negative),
                                .button(rightPress)
                            ]) {
                                StickWidget(label: caps.sticks[1].label,
                                            x: state.axes[2] ?? 0,
                                            y: state.axes[3] ?? 0,
                                            pressed: (state.buttons[rightPress] ?? 0) > 0.5)
                            }
                            // Further surfaces: the Steam Controllers'
                            // trackpads (the 2015 left one on 6 and 7, the
                            // 2026 pair on 6 to 9), each with its press.
                            ForEach(Array(caps.sticks.dropFirst(2).enumerated()), id: \.offset) { _, surface in
                                let press = trackpadPress(axisX: surface.x, steam2015: isSteam)
                                inspectable(label: surface.label, events: [
                                    .axis(surface.x, direction: .positive), .axis(surface.x, direction: .negative),
                                    .axis(surface.y, direction: .positive), .axis(surface.y, direction: .negative)
                                ] + (press.map { [InputEvent.button($0)] } ?? [])) {
                                    StickWidget(label: surface.label,
                                                x: state.axes[surface.x] ?? 0,
                                                y: state.axes[surface.y] ?? 0,
                                                pressed: press.map { (state.buttons[$0] ?? 0) > 0.5 } ?? false)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    ZStack {
                        if has(3) {
                            faceButton(label: labels.face[3] ?? "Y", index: std(3), tint: labels.tint[3] ?? .yellow, key: "Y").offset(y: -24)
                        }
                        if has(0) {
                            faceButton(label: labels.face[0] ?? "A", index: std(0), tint: labels.tint[0] ?? .green, key: "A").offset(y: 24)
                        }
                        if has(2) {
                            // A GameCube pad has B on the left of A and X on
                            // the right, the mirror of the other pads.
                            faceButton(label: labels.face[2] ?? "X", index: std(2), tint: labels.tint[2] ?? .blue, key: "X")
                                .offset(x: caps.family == .gameCube ? 24 : -24)
                        }
                        if has(1) {
                            faceButton(label: labels.face[1] ?? "B", index: std(1), tint: labels.tint[1] ?? .red, key: "B")
                                .offset(x: caps.family == .gameCube ? -24 : 24)
                        }
                    }
                    .frame(width: 96, height: 96)
                }
            }

            // A device with a single stick (the PlayStation Access
            // Controller, some arcade and adaptive pads) gets that one,
            // centered, rather than a phantom second stick.
            if showDiagram, caps.sticks.count == 1, let only = caps.sticks.first {
                HStack {
                    Spacer(minLength: 0)
                    inspectable(label: only.label, events: [
                        .axis(only.x, direction: .positive), .axis(only.x, direction: .negative),
                        .axis(only.y, direction: .positive), .axis(only.y, direction: .negative)
                    ]) {
                        StickWidget(label: only.label,
                                    x: state.axes[only.x] ?? 0,
                                    y: state.axes[only.y] ?? 0,
                                    pressed: false)
                    }
                    Spacer(minLength: 0)
                }
            }

            // The controller's own touchpad with the extra buttons (mute,
            // paddles, FN) beside it, one row. Named for the device so it
            // is never confused with the Mac's trackpad, which is a
            // separate input with its own map. The extras come from the
            // service's snapshot, which includes the KVC-discovered
            // DualSense / DualSense Edge buttons the typed Apple API does
            // not expose, plus every state.buttons[N>12] entry for raw HID
            // gamepads (fight stick macro buttons, arcade pad spares).
            let serviceExtras = controllerService.extraButtonsSnapshot(for: deviceSlot)
                .filter { !(caps.touchpad && $0.index == caps.touchpadPressIndex) }  // the touchpad widget's press
            // Every button the map above does not place is a chip here: the
            // digital LT and RT (6, 7), stick presses on a pad with fewer
            // than two sticks, and the Steam Controller's own buttons.
            // 6 and 7 are the trigger bars' own digital copies on a pad with
            // analog triggers.
            // On a device read from its own descriptor, 6 and 7 are trigger
            // copies only where the parser mirrored an axis onto them; a
            // flight stick or throttle whose slider sits on a trigger slot
            // has real buttons 6 and 7, which were drawn nowhere.
            let triggerCopies: [Int] = {
                guard caps.triggers, !isSteam else { return [] }
                guard let pad = controllerService.rawHIDGamepadSlots[deviceSlot],
                      pad.profile?.identifier.hasPrefix("generic-hid-") == true,
                      case .generic(let generic)? = pad.profile?.layout else { return [6, 7] }
                let plan = HIDExtendedLayoutRegistry.extended(for: generic)
                let physical = Set(plan.reports.flatMap(\.buttons).map(\.index))
                let mirrored = Set(plan.reports.flatMap(\.axes).compactMap(\.digitalButton))
                return [6, 7].filter { mirrored.contains($0) || !physical.contains($0) }
            }()
            let placed = Set(([0, 1, 2, 3, 4, 5, 8, 9, 10] + (caps.sticks.count >= 2 ? [11, 12] : [])
                              + triggerCopies).map(std))
                .union(caps.touchpad ? [caps.touchpadPressIndex] : []).union(serviceExtras.map(\.index))
                // The trackpad widgets' presses, and the 2015 Steam
                // Controller's left pad edge clicks, which the D-pad draws.
                .union(caps.sticks.count >= 2 ? [isSteam ? SteamControllerButton.rightPadClick.rawValue : 12] : [])
                .union(caps.sticks.dropFirst(2).compactMap { trackpadPress(axisX: $0.x, steam2015: isSteam) })
                .union(isSteam ? [8, 9, 10, 11] : [])
            let unplaced = caps.buttons.filter { !placed.contains($0.index) }
                .sorted { $0.index < $1.index }
                .map { GameControllerService.ExtraButton(label: $0.name, index: $0.index,
                                                         pressed: (state.buttons[$0.index] ?? 0) > 0.5) }
            let extras = serviceExtras + unplaced
            if caps.touchpad || !extras.isEmpty {
                HStack(alignment: .center, spacing: 16) {
                    if caps.touchpad {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(caps.family == .steamController2026 ? "Right trackpad (touch)"
                                 : "\(info?.name ?? "Controller") touchpad")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            touchpadSurface(pressed: (state.buttons[caps.touchpadPressIndex] ?? 0) > 0.5)
                        }
                    }
                    if !extras.isEmpty {
                        extraButtonsWidget(extras: extras)
                    }
                    Spacer(minLength: 0)
                }
            }

            // Extra axes row - controllers with sliders, dials, or
            // extra trigger surfaces past the standard LT/RT (axes 4
            // and 5) get a slim live-value bar per axis.
            let drawnAxes = Set(caps.sticks.dropFirst(2).flatMap { [$0.x, $0.y] })
            let extraAxes = controllerService.extraAxesSnapshot(for: deviceSlot).filter { !drawnAxes.contains($0.index) }
            if !extraAxes.isEmpty {
                extraAxesWidget(axes: extraAxes)
            }

            // Hats past the first: a flight stick's POV hats, or a pad with
            // two D-pads. Only the first was drawn, so the others fired
            // rows with nothing on screen.
            let extraHats = state.hats.keys.filter { $0 > 0 }.sorted()
            if showDiagram, !extraHats.isEmpty {
                HStack(spacing: 18) {
                    ForEach(extraHats, id: \.self) { index in
                        let label = "Hat \(index + 1)"
                        VStack(spacing: 4) {
                            inspectable(label: label, events: [
                                .hat(index, direction: .up), .hat(index, direction: .right),
                                .hat(index, direction: .down), .hat(index, direction: .left)
                            ]) {
                                DPadWidget(hat: state.hats[index] ?? (0, 0))
                            }
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func extraAxesWidget(axes: [GameControllerService.ExtraAxis]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra axes")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(axes) { axis in
                HStack(spacing: 8) {
                    Text(axis.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    GeometryReader { proxy in
                        let mid = proxy.size.width / 2
                        let normalized = max(-1, min(1, CGFloat(axis.value)))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green)
                                .frame(width: abs(normalized) * mid, height: 4)
                                .offset(x: normalized >= 0 ? mid : mid + normalized * mid)
                        }
                    }
                    .frame(height: 8)
                    Text(String(format: "%+.2f", axis.value))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.hint)
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(axis.label)
                .accessibilityValue(SpokenLive.axis(axis.value))
            }
        }
        .padding(.top, 4)
    }

    /// True when the extra button has a real, human-meaningful name
    /// (PS, Home, Mute, paddles, FN). False when it's a raw HID
    /// gamepad's "Button N" / "Btn N" fallback label - those become
    /// round placeholder icons instead.
    private func isNamedExtra(_ label: String) -> Bool {
        let lower = label.lowercased()
        if lower.hasPrefix("button ") { return false }
        if lower.hasPrefix("btn ") { return false }
        return true
    }

    /// Spoken value for the combined "Extra buttons" element. Lists each
    /// named button and appends "pressed" to the ones currently held, so
    /// the state is conveyed without relying on the chip's color.
    private func namedExtrasAccessibilityValue(
        _ extras: [GameControllerService.ExtraButton]
    ) -> String {
        extras.map { extra in
            extra.pressed ? "\(extra.label) pressed" : extra.label
        }.joined(separator: ", ")
    }

    @ViewBuilder
    private func extraButtonsWidget(extras: [GameControllerService.ExtraButton]) -> some View {
        // Detected extras come in two flavors:
        //   - Named (PS, Home, Mute, Left Paddle, FN 1, etc.) - chips
        //     with their proper label.
        //   - Unknown (raw HID gamepads' "Button 14" fallback) - round
        //     placeholder icons the user can drag around in edit mode.
        // Each subgroup only renders when its list is non-empty, so a
        // controller with only named extras never shows the "Unknown
        // buttons" header and vice versa.
        let named = extras.filter { isNamedExtra($0.label) }
        let unknown = extras.filter { !isNamedExtra($0.label) }
        VStack(alignment: .leading, spacing: 8) {
            if !named.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra buttons")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    // Each chip is clickable like every other control on the
                    // map: it says what the button is bound to in this preset
                    // and takes you to its row, or offers to add one.
                    WrappingHStackLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(named) { extra in
                            inspectable(label: extra.label, events: [.button(extra.index)]) {
                                extraChip(label: extra.label, pressed: extra.pressed)
                            }
                        }
                    }
                    // The group is named, and each chip keeps its own name.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Extra buttons")
                }
            }
            if !unknown.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unknown buttons")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        ForEach(unknown) { btn in
                            unknownButtonPlaceholder(btn)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    /// One named extra (a paddle, FN, mute) as a chip that lights when it
    /// is held.
    private func extraChip(label: String, pressed: Bool) -> some View {
        let tint: Color = pressed ? .green : .secondary
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(pressed ? Color.white : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(pressed ? 0.85 : 0.15)))
            .overlay(Capsule().stroke(tint.opacity(pressed ? 1 : 0.35), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: pressed)
            .accessibilityLabel("\(label) button")
            .accessibilityValue(pressed ? "pressed" : "released")
    }

    /// Round placeholder icon for an unknown extra button. Shows the
    /// raw index in the center, flashes green while the button is held,
    /// and participates in the visualizer's "Customize layout" drag
    /// machinery via `inspectable()` so the user can reposition it.
    @ViewBuilder
    private func unknownButtonPlaceholder(
        _ button: GameControllerService.ExtraButton
    ) -> some View {
        // The label keys the saved layout position, so it stays as it is;
        // the popover gets a readable title.
        inspectable(label: "extra-\(button.index)", title: "Button \(button.index)",
                    events: [.button(button.index)]) {
            ZStack {
                Circle()
                    .fill(button.pressed
                          ? Color.green.opacity(0.85)
                          : Color.secondary.opacity(0.18))
                Circle()
                    .stroke(button.pressed
                            ? Color.green
                            : Color.secondary.opacity(0.4),
                            lineWidth: 1)
                Text("\(button.index)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(button.pressed ? .white : .primary)
            }
            .frame(width: 28, height: 28)
            .help("Unknown extra button \(button.index): drag in 'Customize layout' to reposition")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Extra button \(button.index)")
            .accessibilityValue(button.pressed ? "pressed" : "released")
        }
    }

    /// Clickable light bar label above the controller: "Light bar" and a
    /// swatch of the preset's color, its rainbow, Off, or Not set. Tap to
    /// open the per-preset light bar picker in a popover anchored right here. The
    /// picker pushes the color to the controller live while the preset
    /// is active, so there is nothing to stop first.
    @ViewBuilder
    private var lightBarStripWidget: some View {
        // Sized to what it says: the words "Light bar", then a small swatch
        // of the preset's color (a rainbow for the RGB cycle), or Off, or
        // Not set. No box behind it.
        Button {
            showLightBarPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "light.beacon.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Light bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if lightBarOff {
                    Text("Off")
                        .font(.caption)
                        .foregroundStyle(.primary)
                } else if lightBarRainbow {
                    Capsule()
                        .fill(LinearGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 30, height: 8)
                } else if let tint = lightBarTint {
                    Capsule()
                        .fill(tint)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: tint.opacity(0.6), radius: 3)
                        .frame(width: 30, height: 8)
                } else {
                    Text("Not set")
                        .font(.caption)
                        .foregroundStyle(.hint)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.hint)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(lightBarTint == nil && !lightBarRainbow && !lightBarOff
              ? "Pick a light bar color for this preset"
              : "Edit this preset's light bar color")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Light bar color")
        .accessibilityValue(lightBarOff ? "off" : lightBarRainbow ? "rainbow" : lightBarTint == nil ? "not set" : "set")
        .accessibilityHint("Opens the light bar color picker")
        .accessibilityAddTraits(.isButton)
        .spotlightAnchor(SpotlightID.lightBarStrip)
        .popover(isPresented: $showLightBarPopover, arrowEdge: .top) {
            trailing()
        }
    }

    /// Every motion channel in both directions, so the popover lists
    /// every motion row the preset has, not only two of them.
    private var motionInspectEvents: [InputEvent] {
        MotionChannel.allCases.flatMap { channel in
            AxisDirection.allCases.map { InputEvent.motion(channel, direction: $0) }
        }
    }

    @ViewBuilder
    private var motionWidgetIfAvailable: some View {
        if info?.supportsMotion == true {
            inspectable(label: "Motion", events: motionInspectEvents) {
                MotionWidget(
                    state: state,
                    integratedRoll: integratedRoll,
                    integratedPitch: integratedPitch,
                    integratedYaw: integratedYaw
                )
            }
        }
    }

    /// Wraps any widget in a Button whose popover anchors at the widget's
    /// own bounds - so taps open a popover *right there* instead of
    /// floating to the middle of the window. In edit mode the widget
    /// instead participates in drag-to-rearrange: each widget remembers an
    /// (x, y) offset from its structural position and applies it here.
    @ViewBuilder
    private func inspectable<Content: View>(
        label: String, title: String? = nil, key: String? = nil, events: [InputEvent],
        draggable: Bool = true, note: String? = nil, editor: VisualizerRegionEditor? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // A stable key for the saved position and the open popover, so a
        // widget whose label follows the family (LB, L1, L) keeps both.
        let key = key ?? label
        // The controller drawing places every control where it really is,
        // so it neither drags nor takes a saved offset.
        let persistedOffset = draggable ? (dragOffsets[key] ?? .zero) : .zero
        let liveOffset: CGSize = (liveDrag?.label == key) ? liveDrag!.translation : .zero
        let totalOffset = CGSize(
            width: persistedOffset.width + liveOffset.width,
            height: persistedOffset.height + liveOffset.height
        )

        if editMode && draggable {
            content()
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            Color.yellow.opacity(0.75),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                        .padding(-2)
                        .allowsHitTesting(false)
                )
                .offset(totalOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            liveDrag = (key, value.translation)
                        }
                        .onEnded { value in
                            let base = dragOffsets[key] ?? .zero
                            dragOffsets[key] = CGSize(
                                width: base.width + value.translation.width,
                                height: base.height + value.translation.height
                            )
                            liveDrag = nil
                            persistOffsets()
                        }
                )
        } else {
            let isOpen = Binding(
                get: { openInspectorLabel == key },
                set: { value in openInspectorLabel = value ? key : nil }
            )
            Button {
                openInspectorLabel = key
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .offset(totalOffset)
            // Fold the widget's own accessibility element (label + live
            // value) up onto the tappable button, and add a hint so
            // VoiceOver users know activating it inspects the bindings.
            .accessibilityElement(children: .combine)
            .accessibilityHint("Inspects bindings for this input")
            .popover(isPresented: isOpen, arrowEdge: .top) {
                inspectorContent(label: title ?? label, events: events, note: note, editor: editor)
            }
        }
    }

    // MARK: - Layout persistence

    /// Reload saved offsets for the currently-selected controller model.
    /// Called on appear and whenever the slot changes.
    private func loadOffsets() {
        guard let raw = UserDefaults.standard.dictionary(forKey: layoutStorageKey)
                as? [String: [String: Double]] else {
            dragOffsets = [:]
            return
        }
        dragOffsets = raw.compactMapValues { dict in
            guard let w = dict["w"], let h = dict["h"] else { return nil }
            return CGSize(width: w, height: h)
        }
    }

    /// Persist the current offsets dictionary for the active controller
    /// model. UserDefaults can't store CGSize directly so we encode each
    /// entry as ["w": width, "h": height].
    private func persistOffsets() {
        let encoded = dragOffsets.mapValues { ["w": Double($0.width),
                                               "h": Double($0.height)] }
        UserDefaults.standard.set(encoded, forKey: layoutStorageKey)
    }

    /// Single face button with its own anchored popover.
    private func faceButton(label: String, index: Int, tint: Color, key: String) -> some View {
        inspectable(label: label, key: key, events: [.button(index)]) {
            FaceButtonGlyph(label: label,
                            pressed: (state.buttons[index] ?? 0) > 0.5,
                            tint: tint)
        }
    }

    /// One menu pill (Share / Home / Menu) wrapped in inspectable.
    private func menuPill(label: String, index: Int, key: String) -> some View {
        let pressed = (state.buttons[index] ?? 0) > 0.5
        return inspectable(label: label, key: key, events: [.button(index)]) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(pressed ? .green : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(pressed ? Color.green.opacity(0.20) : Color.secondary.opacity(0.10))
                )
                .overlay(Capsule().stroke(pressed ? Color.green : Color.secondary.opacity(0.3), lineWidth: 0.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label) button")
                .accessibilityValue(pressed ? "pressed" : "released")
        }
    }

    // MARK: - Inspector (dead helper kept for symmetry - per-widget
    // popovers anchor themselves via inspectable() instead).

    /// A binding match enriched with the joystick group it lives in and its
    /// 1-based position within that group, so the popover can show "#3" next
    /// to each row and jump back to the exact same row in the editor.
    fileprivate struct BindingMatch: Identifiable {
        let id: UUID
        let binding: BindingModel
        let joystickIndex: Int
        let displayNumber: Int
    }

    /// Locate every binding across every joystick group whose input matches
    /// one of the widget's events. Built outside of ViewBuilder because for
    /// loops aren't allowed in result builders.
    private func matches(for events: [InputEvent]) -> [BindingMatch] {
        let serializedSet = Set(events.map(\.serialized))
        var collected: [BindingMatch] = []
        for (joystickIndex, group) in preset.joysticks.enumerated() {
            for (bindIndex, binding) in group.bindings.enumerated()
                where serializedSet.contains(binding.input.serialized) {
                collected.append(BindingMatch(
                    id: binding.id,
                    binding: binding,
                    joystickIndex: joystickIndex,
                    displayNumber: bindIndex + 1
                ))
            }
        }
        return collected
    }

    /// Popover content for an inspectable widget. Each binding row is its
    /// own button so the user can tap the description to jump straight to
    /// the editor; nothing requires hitting a tiny Edit button.
    @ViewBuilder
    fileprivate func inspectorContent(label: String, events: [InputEvent], note: String? = nil,
                                      editor: VisualizerRegionEditor? = nil) -> some View {
        let matchingBindings = matches(for: events)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.headline)
                Text(inspectorSubtitle(count: matchingBindings.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // What the drawing knows about this control on this pad
                // (a system gesture, a profile caveat).
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            // Motion widget gets an extra "Reset gyroscope" action so
            // the user can re-zero on a flat surface without leaving
            // the visualizer.
            if label == "Motion" {
                gyroResetActionRow
                Divider()
            }
            if matchingBindings.isEmpty {
                Text("Nothing in this preset uses it yet. Add a row in the editor and pick what it should do.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = events.first {
                    Button {
                        jump(EditorJumpTarget(joystickIndex: slot, inputSerialized: first.serialized))
                    } label: {
                        Label("Open the editor", systemImage: "pencil")
                            .font(.callout)
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .help("Open this preset's editor")
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(matchingBindings) { match in
                        Button {
                            jump(EditorJumpTarget(joystickIndex: match.joystickIndex,
                                                  inputSerialized: match.binding.input.serialized,
                                                  bindingID: match.binding.id))
                        } label: {
                            inspectorRow(match, widgetHasSeveralInputs: Set(events.map(\.serialized)).count > 1)
                        }
                        .buttonStyle(.plain)
                        .help("Show this row in the editor")
                    }
                }
            }
            // A zone or region also has its own editor, where it is drawn.
            if let editor, onOpenRegionEditor != nil {
                Button {
                    openRegionEditor(editor)
                } label: {
                    Label(editor.buttonTitle, systemImage: editor.systemImage)
                        .font(.callout)
                }
                .buttonStyle(.solidSecondaryCompact)
                .help(editor == .touchpadSetup ? "Draw and name this preset's touchpad zones"
                      : editor == .screenRegions ? "Draw and name this preset's screen regions"
                      : "Draw and name this preset's stick zones")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// The device this map shows and how many rows use the control.
    private func inspectorSubtitle(count: Int) -> String {
        let device = capabilities.deviceName
        let use = count == 0 ? "not used in this preset" : count == 1 ? "1 row in this preset" : "\(count) rows in this preset"
        return device.isEmpty ? use.prefix(1).uppercased() + use.dropFirst() : "\(device), \(use)"
    }

    /// One row of the inspector: what the control does, in words. The
    /// row's own note leads when it has one, the outputs follow, then the
    /// ways it fires besides a plain press.
    private func inspectorRow(_ match: BindingMatch, widgetHasSeveralInputs: Bool) -> some View {
        let b = match.binding
        let outputs = b.outputs.map(\.displayName).joined(separator: " + ")
        let note = (b.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var details: [String] = []
        if !note.isEmpty, !outputs.isEmpty { details.append("Sends " + outputs) }
        if let hold = b.holdOutputs, !hold.isEmpty {
            details.append("Held: " + hold.map(\.displayName).joined(separator: " + "))
        }
        if let double = b.doubleTapOutputs, !double.isEmpty {
            details.append("Double tap: " + double.map(\.displayName).joined(separator: " + "))
        }
        if !b.modifiers.isEmpty {
            let family = controllerService.naming(forSlot: deviceSlot, presetFamily: preset.buttonFamily)
            details.append("Only while holding " + b.modifiers
                .map { ButtonNames.inputName($0, family: family.family, model: family.model) }
                .joined(separator: " and "))
        }
        if let steps = b.macroSteps, !steps.isEmpty { details.append("Runs a macro of \(steps.count) steps") }
        if b.toggleMode == true { details.append("Toggles: press once to hold, again to let go") }
        if b.turboEnabled == true { details.append("Repeats rapidly while held") }
        if let n = b.repeatCount, n > 1 { details.append("Fires \(n) times") }
        if preset.joysticks.count > 1 { details.append("On \(groupDeviceName(match.joystickIndex))") }
        let headline = !note.isEmpty ? note : (outputs.isEmpty ? "Nothing chosen yet" : outputs)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // A widget with several inputs (a stick's four directions,
                // a touchpad's zones) says which one this row is.
                if let info = regionInfo(for: b.input) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(regionPaletteColor(at: info.colorIndex))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                        Text(info.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else if widgetHasSeveralInputs || !b.modifiers.isEmpty {
                    Text(inspectorName(match))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(headline)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(details, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.hint)
                .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this row in the editor")
    }

    /// The device a group reads, by the name its device menu shows.
    private func groupDeviceName(_ index: Int) -> String {
        guard index < preset.joysticks.count else { return "Input Device \(index)" }
        if let name = preset.joysticks[index].customName, !name.isEmpty { return name }
        if let mac = preset.joysticks[index].macInputName { return mac }
        let slots = controllerService.effectiveSlots(for: preset.joysticks)
        return slots[index].flatMap { controllerService.controllerDetails[$0]?.name } ?? "Input Device \(index)"
    }

    /// Closes the popover first and opens the editor a beat later, so the
    /// popover's close and the editor's slide do not land in one frame.
    private func jump(_ target: EditorJumpTarget) {
        openInspectorLabel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { onJump?(target) }
    }

    /// The same for a region editor sheet: the popover closes first.
    private func openRegionEditor(_ editor: VisualizerRegionEditor) {
        openInspectorLabel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { onOpenRegionEditor?(editor) }
    }

    // MARK: - Motion popover extras

    /// Tiny row injected at the top of the Motion popover with a
    /// "Reset gyroscope" button. Mirrors the toolbar quick-zero in
    /// PresetEditor so the user can re-zero without leaving the
    /// visualizer.
    @ViewBuilder
    private var gyroResetActionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                resetGyroFromVisualizer()
            } label: {
                Label("Reset gyroscope (re-zero now)", systemImage: "scope")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.solidCompact)
            .help("Sample the controller's current motion as the new resting baseline. Hold the controller flat and steady, then click.")

            if let msg = gyroResetFeedback {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
    }

    /// Re-zero every connected motion-capable controller, the same as
    /// the editor's Quick Zero.
    private func resetGyroFromVisualizer() {
        var count = 0
        var moving = 0
        // Through the service's re-zero: it averages the recent gyro
        // samples and only stores a zero from a pad that is still. One raw
        // sample, taken whatever the pad was doing, stored the noise or
        // the movement as rest.
        for slot in controllerService.connectedControllers.indices {
            guard controllerService.rezeroMotion(slot: slot) else { continue }
            if controllerService.lastRezeroStoredZero { count += 1 } else { moving += 1 }
        }
        // Reset the parent's integrated angles too so the on-screen
        // model immediately snaps back to center instead of slowly
        // drifting away from whatever orientation it was showing.
        integratedRoll = 0
        integratedPitch = 0
        integratedYaw = 0
        withAnimation(.easeInOut(duration: 0.18)) {
            gyroResetFeedback = count == 0 && moving == 0
                ? "No motion-capable controller connected"
                : count == 0
                    ? "Moving, hold it still and try again"
                    : "Zeroed on \(count) controller\(count == 1 ? "" : "s")"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.18)) {
                gyroResetFeedback = nil
            }
        }
    }

    // MARK: - Deadzones on the drawing

    /// The deadzones this group's rows set on a drawn control, for the
    /// canvas to mark as the deadzone calibration sheet does. Every axis
    /// row in this group that reads the control counts, at the deadzone the
    /// engine uses for it (the row's own, else the 25% default its Options
    /// show, as the sheet does); an outer deadzone only when a row sets one
    /// below 100%, as the sheet draws its green ring. Each way takes the
    /// first row to react there; a way no row reads takes the opposite
    /// way's. Nil when no row in this group reads the control.
    private func canvasDeadzone(_ c: PlacedControl, layout: ControllerLayout) -> CanvasDeadzone? {
        guard slot < preset.joysticks.count else { return nil }
        let rows = preset.joysticks[slot].bindings.filter { $0.input.type == .axis }
        guard !rows.isEmpty else { return nil }
        // Each axis the control drives, and the ways it moves.
        var ways: [Int: (positive: DeadzoneWay, negative: DeadzoneWay?)] = [:]
        var oneWay = false
        for a in c.inputs.axes {
            switch a.role {
            case .y: ways[a.index] = (.down, .up)
            case .x: ways[a.index] = (.right, .left)
            case .analog:
                ways[a.index] = a.unipolar ? (.right, nil) : (.right, .left)
                if a.unipolar { oneWay = true }
            }
        }
        if let pos = layout.surface(forControl: c.id)?.positionAxes {
            ways[pos.x] = (.right, .left)
            ways[pos.y] = (.down, .up)
        }
        guard !ways.isEmpty else { return nil }
        var inner: [DeadzoneWay: [Float]] = [:], outer: [DeadzoneWay: Float] = [:]
        for row in rows {
            guard let w = ways[row.input.index] else { continue }
            let dz = row.deadzone ?? 0.25
            // The way the control physically moves for this row, after invert.
            var hit: [DeadzoneWay] = []
            switch row.input.axisDirection {
            case .positive?: hit = [row.invertAxis == true ? w.negative : w.positive].compactMap { $0 }
            case .negative?: hit = [row.invertAxis == true ? w.positive : w.negative].compactMap { $0 }
            case nil: hit = [w.positive] + [w.negative].compactMap { $0 }
            }
            for way in hit {
                inner[way, default: []].append(dz)
                if let o = row.outerDeadzone, o < 0.99 { outer[way] = min(outer[way] ?? 1, o) }
            }
        }
        guard !inner.isEmpty else { return nil }
        let first = inner.mapValues { $0.min() ?? 0.25 }
        func value(_ w: DeadzoneWay, _ opposite: DeadzoneWay, _ across: [DeadzoneWay]) -> Float {
            first[w] ?? first[opposite] ?? across.compactMap { first[$0] }.max() ?? 0.25
        }
        var mark = CanvasDeadzone()
        mark.right = value(.right, .left, [.down, .up])
        mark.left = value(.left, .right, [.down, .up])
        mark.down = value(.down, .up, [.right, .left])
        mark.up = value(.up, .down, [.right, .left])
        mark.outerRight = outer[.right] ?? 1
        mark.outerLeft = outer[.left] ?? 1
        mark.outerDown = outer[.down] ?? 1
        mark.outerUp = outer[.up] ?? 1
        func pct(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
        var help: String
        if oneWay {
            mark.thresholds = Array(Set(inner[.right] ?? [])).sorted()
            help = mark.thresholds.count > 1
                ? "Rows start at " + mark.thresholds.map(pct).joined(separator: ", ") + ": red up to the first, an orange line at each"
                : "Deadzone " + pct(mark.right)
            if let o = outer[.right] { help += ", full push at " + pct(o) }
        } else {
            // Ways with the same deadzone named together.
            let names: [DeadzoneWay: String] = [.right: "right", .left: "left", .down: "down", .up: "up"]
            let read = DeadzoneWay.allCases.filter { first[$0] != nil }
            let byValue = Dictionary(grouping: read) { first[$0] ?? 0 }
            if byValue.count == 1, let v = byValue.keys.first {
                help = "Deadzone " + pct(v)
            } else {
                help = "Deadzone " + byValue.keys.sorted().map { v in
                    pct(v) + " " + (byValue[v] ?? []).map { names[$0] ?? "" }.joined(separator: " and ")
                }.joined(separator: ", ")
            }
            let moves = Set(ways.values.flatMap { [$0.positive] + [$0.negative].compactMap { $0 } })
            let unreadNames = DeadzoneWay.allCases.filter { first[$0] == nil && moves.contains($0) }.map { names[$0] ?? "" }
            if !unreadNames.isEmpty { help += "; no row reads " + unreadNames.joined(separator: " or ") }
            // A later row the same way: the ring is the first one.
            let later = DeadzoneWay.allCases.compactMap { w -> String? in
                let starts = Array(Set(inner[w] ?? [])).sorted()
                return starts.count > 1 ? names[w].map { $0 + " " + starts.dropFirst().map(pct).joined(separator: ", ") } : nil
            }
            if !later.isEmpty { help += "; the ring is the first row each way, others start at " + later.joined(separator: "; ") }
            let outers = DeadzoneWay.allCases.compactMap { outer[$0] }
            if let o = outers.min() { help += "; full push at " + pct(o) }
        }
        mark.help = help
        return mark
    }

    /// The motion rows' deadzones, under the motion meter: one bar per
    /// motion channel this group's rows read, drawn as the Motion panel in
    /// a row's Options draws it (centered, the gray band the deadzone, the
    /// fill green when a row would fire).
    @ViewBuilder
    private func motionDeadzoneMeters(_ st: ControllerState) -> some View {
        let rows = slot < preset.joysticks.count ? preset.joysticks[slot].bindings.filter { $0.input.type == .motion } : []
        let channels = MotionChannel.allCases.filter { ch in rows.contains { $0.input.motionChannel == ch } }
        if !channels.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(channels, id: \.self) { ch in
                    let mine = rows.filter { $0.input.motionChannel == ch }
                    MotionDeadzoneMeter(channel: ch, value: st.motion[ch] ?? 0, rows: mine)
                }
            }
            .frame(maxWidth: 320)
        }
    }

    // MARK: - Thresholds

    /// Return the deadzone of the first binding that uses this axis half,
    /// for display as a marker on the trigger widget. Falls back to 0.25.
    private func thresholdForAxis(_ index: Int, dir: AxisDirection) -> Float {
        for joystick in preset.joysticks {
            for binding in joystick.bindings
                where binding.input.type == .axis
                    && binding.input.index == index
                    && binding.input.axisDirection == dir {
                return binding.deadzone ?? 0.25
            }
        }
        return 0.25
    }
}

// MARK: - Widget components

private struct StickWidget: View {
    let label: String
    let x: Float
    let y: Float
    let pressed: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(pressed ? Color.green.opacity(0.25) : Color.secondary.opacity(0.18))
                Circle()
                    .stroke(pressed ? Color.green : Color.secondary.opacity(0.4), lineWidth: 1.5)
                // Crosshair
                Path { p in
                    p.move(to: CGPoint(x: 36, y: 0)); p.addLine(to: CGPoint(x: 36, y: 72))
                    p.move(to: CGPoint(x: 0, y: 36)); p.addLine(to: CGPoint(x: 72, y: 36))
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                // Thumb dot
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .offset(x: CGFloat(x) * 26, y: CGFloat(y) * 26)
                    .animation(.linear(duration: 0.03), value: x)
                    .animation(.linear(duration: 0.03), value: y)
            }
            .frame(width: 72, height: 72)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    /// Spoken description of the live analog position and press state, so
    /// VoiceOver users hear where the stick is instead of a silent circle.
    private var accessibilityValue: String {
        SpokenLive.stick(x: x, y: y) + (pressed ? ", pressed" : "")
    }
}

private struct TriggerWidget: View {
    let label: String
    let value: Float
    let threshold: Float
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 22, height: 80)
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.gradient)
                    .frame(width: 22, height: max(2, CGFloat(value) * 80))
                    .animation(.linear(duration: 0.04), value: value)
                // Threshold marker
                Rectangle()
                    .fill(Color.orange.opacity(0.7))
                    .frame(width: 30, height: 1)
                    .offset(y: -CGFloat(threshold) * 80)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", min(1, max(0, value)) * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.hint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) trigger")
        .accessibilityValue(SpokenLive.trigger(value))
    }
}

private struct ShoulderWidget: View {
    let label: String
    let pressed: Bool

    var body: some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.green.opacity(0.25) : Color.secondary.opacity(0.15))
            Capsule()
                .stroke(pressed ? Color.green : Color.secondary.opacity(0.35), lineWidth: 1)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(pressed ? .green : .secondary)
        }
        .frame(width: 56, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) shoulder")
        .accessibilityValue(pressed ? "pressed" : "released")
    }
}

private struct DPadWidget: View {
    let hat: (x: Float, y: Float)

    var body: some View {
        let up = hat.y > 0.5
        let down = hat.y < -0.5
        let left = hat.x < -0.5
        let right = hat.x > 0.5
        VStack(spacing: 2) {
            arrow(up: true, active: up)
            HStack(spacing: 2) {
                arrow(left: true, active: left)
                Color.clear.frame(width: 20, height: 20)
                arrow(right: true, active: right)
            }
            arrow(down: true, active: down)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("D-pad")
        .accessibilityValue(directionValue(up: up, down: down, left: left, right: right))
    }

    /// Spoken direction the D-pad is currently pressed toward, combining
    /// the two axes so diagonals read naturally (for example "up right").
    private func directionValue(up: Bool, down: Bool, left: Bool, right: Bool) -> String {
        var parts: [String] = []
        if up { parts.append("up") }
        if down { parts.append("down") }
        if left { parts.append("left") }
        if right { parts.append("right") }
        return parts.isEmpty ? "centered" : parts.joined(separator: " ")
    }

    private func arrow(up: Bool = false, down: Bool = false, left: Bool = false, right: Bool = false, active: Bool) -> some View {
        let icon: String =
            up ? "arrowtriangle.up.fill" :
            down ? "arrowtriangle.down.fill" :
            left ? "arrowtriangle.left.fill" :
            "arrowtriangle.right.fill"
        return Image(systemName: icon)
            .font(.body)
            .foregroundStyle(active ? Color.green : Color.secondary.opacity(0.55))
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color.green.opacity(0.18) : Color.secondary.opacity(0.10))
            )
    }
}

private struct FaceButtonGlyph: View {
    let label: String
    let pressed: Bool
    let tint: Color

    /// PlayStation glyphs are drawn as symbols at one fixed size. As text,
    /// the four characters come out at four different sizes.
    private var symbol: String? {
        switch label {
        case "✕": return "xmark"
        case "○": return "circle"
        case "□": return "square"
        case "△": return "triangle"
        default: return nil
        }
    }
    private var spokenName: String {
        switch label {
        case "✕": return "Cross"
        case "○": return "Circle"
        case "□": return "Square"
        case "△": return "Triangle"
        // Face button names by position, spoken in full.
        case "S": return "South"
        case "E": return "East"
        case "W": return "West"
        case "N": return "North"
        default: return label
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(pressed ? tint.opacity(0.4) : Color.secondary.opacity(0.18))
            Circle()
                .stroke(pressed ? tint : Color.secondary.opacity(0.35), lineWidth: 1.5)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(pressed ? tint : tint.opacity(0.85))
            } else {
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(pressed ? tint : tint.opacity(0.85))
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenName) button")
        .accessibilityValue(pressed ? "pressed" : "released")
    }
}

private struct TouchpadWidget: View {
    @Environment(\.visualizerSuspended) private var suspended
    /// Touchpad button (index 13) state. When the user physically pushes
    /// the touchpad down (not just touches it), this flips to true and the
    /// widget glows green to signal a click vs a swipe.
    let pressed: Bool

    /// The zones of the preset being shown. Regions belong to presets, so
    /// the visualizer draws the ones this preset defines rather than
    /// whatever the service happens to be holding; the service's list is
    /// used only when the preset has none of its own (while a draft is
    /// being edited, for instance).
    var presetRegions: [TouchpadRegion] = []

    /// Single sample of a finger's position with the timestamp it was
    /// captured. The view ages each point and uses age to compute opacity
    /// + size, producing the "whoosh" trail behind the moving finger.
    private struct TrailPoint: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let time: Date
    }

    @State private var trailF0: [TrailPoint] = []
    @State private var trailF1: [TrailPoint] = []

    /// How long a trail point lingers before fading away. Short enough to
    /// feel responsive, long enough that a fast swipe leaves a visible arc.
    private let trailDuration: TimeInterval = 0.35
    /// Hard cap on how many trail samples we retain per finger. Even at a
    /// short trailDuration the sample timer can overrun this on rapid
    /// motion; the cap keeps per-frame render cost bounded. 24 still
    /// produces a visually continuous arc on a fast swipe.
    private let maxTrailPoints = 24
    /// Width divided by height of the real surface. A DualSense pad is a
    /// wide letterbox, a Mac trackpad is close to 3:2, and drawing one in
    /// the other's shape puts every zone in the wrong place: a zone that
    /// covers the bottom third of a Mac trackpad was being drawn as a thin
    /// strip. Defaults to the DualSense pad.
    var surfaceAspect: CGFloat = 220.0 / 70.0

    /// Width / height of the rendered touchpad rect, in the surface's shape.
    private var pad: CGSize {
        let width: CGFloat = 220
        return CGSize(width: width, height: max(60, min(150, width / max(0.6, surfaceAspect))))
    }
    /// Sampled-coordinate range (matches the helper subprocess output).
    private let coordScale = CGSize(width: 1920, height: 1080)

    /// Snapshot of the user-defined detection regions (from the
    /// Touchpad Calibration sheet) so the visualizer can overlay
    /// them. We refresh this on every render tick along with the
    /// trail samples - cheap because the region list is short and
    /// allRegions() just snapshots an Array under the service lock.
    @State private var regions: [TouchpadRegion] = []
    /// IDs of regions currently being touched, so we can light them
    /// up the same way TouchpadCalibrationView does.
    @State private var pressedRegionIDs: Set<UUID> = []
    /// The last tap gesture the pad reported and when, so the widget can
    /// flash "Tap" or "Two-finger tap" for a moment.
    @State private var lastTap: TouchpadGestureKind?
    @State private var lastTapAt: Date = .distantPast

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(pressed
                      ? Color.green.opacity(0.35)
                      : Color.black.opacity(0.25))
                .animation(.easeOut(duration: 0.12), value: pressed)
            RoundedRectangle(cornerRadius: 8)
                .stroke(pressed ? Color.green : Color.mint.opacity(0.5),
                        lineWidth: pressed ? 2 : 1)
                .shadow(color: pressed ? Color.green.opacity(0.7) : .clear,
                        radius: pressed ? 10 : 0)
                .animation(.easeOut(duration: 0.12), value: pressed)

            // Faint grid so the surface reads as a real touchpad.
            Path { p in
                p.move(to: CGPoint(x: pad.width / 2, y: 6))
                p.addLine(to: CGPoint(x: pad.width / 2, y: pad.height - 6))
                p.move(to: CGPoint(x: 12, y: pad.height / 2))
                p.addLine(to: CGPoint(x: pad.width - 12, y: pad.height / 2))
            }
            .stroke(Color.mint.opacity(0.15), lineWidth: 0.5)

            // Detection regions overlay. The visualizer is the same
            // surface the user defined regions on in
            // TouchpadCalibrationView, so we mirror that view's region
            // rendering 1:1 (palette color, fill/stroke, "lit up when
            // pressed" highlight). Always rendered behind the finger
            // trails so a region's color shows through.
            ForEach(regions) { region in
                regionRect(region)
            }

            // Trails: rendered through a single Canvas (one draw call
            // for all points per finger) instead of dozens of SwiftUI
            // Circle views with expensive .blur modifiers. This was the
            // root cause of the visible choppiness - the previous
            // approach created up to 132 blurred-circle subviews per
            // frame and the offscreen blur passes were saturating the
            // GPU. Canvas draws everything in one pass with native
            // CoreGraphics fills.
            trailCanvas

            // Dot for the most recent position. Kept as a regular view
            // (only 2 of them) so we get the natural shadow + crispness
            // of SwiftUI shape rendering for the focal point.
            dotRender(point: trailF0.last, hue: .mint, base: 12)
            dotRender(point: trailF1.last, hue: .cyan, base: 10)

            Text("Touchpad")
                .font(.caption2)
                .foregroundStyle(.hint)
                .position(x: 32, y: 8)

            // A tap has no lasting state to draw, so it is shown as a
            // short flash of its name at the top edge.
            if let tap = lastTap, Date().timeIntervalSince(lastTapAt) < 0.7 {
                Text(tap == .oneFingerTap ? "Tap" : tap == .doubleTap ? "Double tap" : "Two-finger tap")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.mint)
                    .position(x: pad.width - 44, y: 8)
                    .transition(.opacity)
            }
        }
        .frame(width: pad.width, height: pad.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touchpad")
        .accessibilityValue(pressed ? "pressed" : "released")
        // 60 Hz sampling. Higher rates produced visibly worse
        // performance because each tick invalidated @State and forced
        // SwiftUI to rebuild the whole widget body. 30 Hz, the same as the
        // panel around it: at 60 the trail write re-rendered this widget
        // twice for every frame the parent drew, and that extra layout
        // work on the main thread was paid for by the engine's poll timer,
        // which reached the pointer as touchpad lag. The data source is
        // event-driven so the sampled position is always fresh.
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { now in
            // Paused while another app is in front, like the panel's clock,
            // and under the editor.
            guard NSApp.isActive, !suspended else { return }
            sampleAndPrune(now: now)
            refreshRegionState()
            for kind in [TouchpadGestureKind.oneFingerTap, .doubleTap, .twoFingerTap]
            where TouchpadService.shared.peekGesture(kind) {
                if lastTap != kind || now.timeIntervalSince(lastTapAt) > 0.3 {
                    lastTap = kind; lastTapAt = now
                }
            }
        }
        // Hold the touchpad while the widget is on screen. MappingEngine
        // holds it separately when a preset uses it; the count keeps the
        // touch state until the last one lets go.
        .onAppear {
            TouchpadService.shared.retain()
            regions = presetRegions.isEmpty ? TouchpadService.shared.allRegions() : presetRegions
        }
        .onChange(of: presetRegions) { _, new in
            regions = new.isEmpty ? TouchpadService.shared.allRegions() : new
        }
        .onDisappear { TouchpadService.shared.release() }
    }

    /// Per-region rect overlay. Same coordinate space as the trail
    /// rendering: normalized [0...1] inside the pad rectangle.
    @ViewBuilder
    private func regionRect(_ region: TouchpadRegion) -> some View {
        let isPressed = pressedRegionIDs.contains(region.id)
        let color = paletteColor(at: region.colorIndex)
        let rect = CGRect(
            x: CGFloat(region.minX) * pad.width,
            y: CGFloat(region.minY) * pad.height,
            width: CGFloat(region.maxX - region.minX) * pad.width,
            height: CGFloat(region.maxY - region.minY) * pad.height)
        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(isPressed ? 0.6 : 0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(isPressed ? 1 : 0.55),
                            lineWidth: isPressed ? 1.5 : 0.75)
            )
            .frame(width: max(2, rect.width), height: max(2, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    /// Pull the current region list + pressed set out of the service.
    /// Single lock acquisition via `snapshotRegions()` (was 1 + N locks
    /// before, one per region for isRegionPressed). At 60 Hz with ~10
    /// regions this used to do ~600 NSLock ops/sec; now it's 60.
    private func refreshRegionState() {
        let (snapshot, pressed) = TouchpadService.shared.snapshotRegions()
        if presetRegions.isEmpty, snapshot.map(\.id) != regions.map(\.id) {
            regions = snapshot
        }
        if pressed != pressedRegionIDs {
            pressedRegionIDs = pressed
        }
    }

    /// Mirror of TouchpadCalibrationView.paletteColor so the visualizer
    /// renders each region in the same color the user picked in the
    /// calibration sheet. Duplicated rather than shared because both
    /// views use a static palette; the entries never change.
    private func paletteColor(at index: Int) -> Color {
        let palette = TouchpadRegion.colorPalette
        let safeIndex = max(0, min(palette.count - 1, index))
        switch palette[safeIndex] {
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green":  return .green
        case "mint":   return .mint
        case "teal":   return .teal
        case "cyan":   return .cyan
        case "blue":   return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink":   return .pink
        case "brown":  return .brown
        default:       return .gray
        }
    }

    /// Single-pass Canvas that renders both fingers' trails as plain
    /// fills. Replaces the previous ForEach-of-blurred-Circles approach
    /// which was the main source of touchpad lag (blur is implemented
    /// as an offscreen pass per view; ~130 of those per frame swamped
    /// the GPU).
    private var trailCanvas: some View {
        // Pause the 60 Hz clock when there is nothing to animate. With both
        // trail buffers empty the Canvas was repainting an empty pad 60x/sec
        // for the whole time a touchpad controller is connected. A finger-down
        // appends to trailF0/trailF1 (@State), which re-runs body and resumes
        // this same-identity timeline on the same render pass (no added latency).
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: suspended || (trailF0.isEmpty && trailF1.isEmpty))) { context in
            Canvas { ctx, _ in
                drawTrail(into: ctx, points: trailF0,
                          color: .mint, at: context.date)
                drawTrail(into: ctx, points: trailF1,
                          color: .cyan, at: context.date)
            }
        }
        .frame(width: pad.width, height: pad.height)
        .allowsHitTesting(false)
    }

    /// Helper that draws one finger's trail into the Canvas context.
    /// Older points are smaller and more transparent than newer ones,
    /// matching the original look but without the expensive per-point
    /// blur. Kept as a static-ish function so the closure stays simple
    /// and the SwiftUI type-checker doesn't time out on a complex body.
    private func drawTrail(into ctx: GraphicsContext, points: [TrailPoint],
                           color: Color, at now: Date) {
        for p in points {
            let age = now.timeIntervalSince(p.time)
            let factor = max(0, 1 - age / trailDuration)
            guard factor > 0.02 else { continue }
            let radius = (4 + 8 * factor) / 2
            let x = p.x / coordScale.width * pad.width
            let y = p.y / coordScale.height * pad.height
            let rect = CGRect(x: x - radius, y: y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(color.opacity(0.45 * factor)))
        }
    }

    /// Solid "current finger" dot rendered on top of the trail so the
    /// active position pops out from the fading wash behind it.
    @ViewBuilder
    private func dotRender(point: TrailPoint?, hue: Color, base: CGFloat) -> some View {
        if let p = point {
            Circle()
                .fill(hue)
                .frame(width: base, height: base)
                .shadow(color: hue.opacity(0.7), radius: 4)
                .position(x: p.x / coordScale.width * pad.width,
                          y: p.y / coordScale.height * pad.height)
        }
    }

    /// Append the current finger positions to the trail buffers (if a
    /// finger is down) and drop any samples older than `trailDuration`.
    /// Also enforces `maxTrailPoints` so a stuck timer can't grow the
    /// buffer unboundedly between prune sweeps.
    private func sampleAndPrune(now: Date) {
        // Idle gate: with no finger on the pad and no fading trail left to
        // prune, every line below is a no-op - but the array mutations still
        // dirtied @State 60x/second and re-rendered the widget continuously
        // while a touchpad controller was merely connected. Bail out first.
        if TouchpadService.shared.currentPosition(finger: 0) == nil,
           TouchpadService.shared.currentPosition(finger: 1) == nil,
           trailF0.isEmpty, trailF1.isEmpty {
            return
        }
        if let p = TouchpadService.shared.currentPosition(finger: 0) {
            trailF0.append(TrailPoint(x: CGFloat(p.x), y: CGFloat(p.y), time: now))
        }
        if let p = TouchpadService.shared.currentPosition(finger: 1) {
            trailF1.append(TrailPoint(x: CGFloat(p.x), y: CGFloat(p.y), time: now))
        }
        let cutoff = now.addingTimeInterval(-trailDuration)
        trailF0.removeAll { $0.time < cutoff }
        trailF1.removeAll { $0.time < cutoff }
        if trailF0.count > maxTrailPoints {
            trailF0.removeFirst(trailF0.count - maxTrailPoints)
        }
        if trailF1.count > maxTrailPoints {
            trailF1.removeFirst(trailF1.count - maxTrailPoints)
        }
    }
}

/// A way a drawn control moves, for the deadzone marked each way.
private enum DeadzoneWay: Int, CaseIterable { case right, left, down, up }

/// One motion channel's rows on the Live Visualizer: the Motion panel's
/// bar from a row's Options (centered, the gray band the deadzone, the fill
/// green when a row would fire), with every row on the channel: a band out
/// to each side's first row, the side no row listens to dimmed.
private struct MotionDeadzoneMeter: View {
    let channel: MotionChannel
    let value: Float
    let rows: [BindingModel]

    /// The Motion panel's full scale: gyro rates in rad/s, the rest about -1...1.
    private var scale: Float {
        switch channel {
        case .gyroX, .gyroY, .gyroZ: return 3
        default: return 1
        }
    }

    /// The engine's deadzone for a motion row with none of its own.
    private func deadzone(_ row: BindingModel) -> Float {
        row.deadzone ?? (MappingEngine.drivesPointer(row) ? 0.05 : Float(MappingEngine.motionSwitchDeadzone))
    }

    /// The first row's deadzone on each side (after invert), nil when no row listens there.
    private var sides: (positive: Float?, negative: Float?) {
        var pos: Float?, neg: Float?
        for row in rows {
            let dz = deadzone(row)
            let flip = row.invertAxis == true
            switch row.input.axisDirection {
            case .positive?: if flip { neg = min(neg ?? dz, dz) } else { pos = min(pos ?? dz, dz) }
            case .negative?: if flip { pos = min(pos ?? dz, dz) } else { neg = min(neg ?? dz, dz) }
            case nil: pos = min(pos ?? dz, dz); neg = min(neg ?? dz, dz)
            }
        }
        return (pos, neg)
    }

    private var firing: Bool {
        rows.contains { MappingEngine.motionFires(value: value, direction: $0.input.axisDirection,
                                                  invert: $0.invertAxis == true, deadzone: deadzone($0)) }
    }

    private var help: String {
        func pct(_ v: Float) -> String { String(format: "%.2g", v) }
        let s = sides
        let unit = scale == 3 ? " rad/s" : ""
        switch (s.positive, s.negative) {
        case let (p?, n?) where p == n: return "\(channel.displayName): deadzone \(pct(p))\(unit)"
        case let (p?, n?): return "\(channel.displayName): deadzone \(pct(p))\(unit) +, \(pct(n))\(unit) \u{2212}"
        case let (p?, nil): return "\(channel.displayName): deadzone \(pct(p))\(unit), + only"
        case let (nil, n?): return "\(channel.displayName): deadzone \(pct(n))\(unit), \u{2212} only"
        default: return channel.displayName
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(channel.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            meter.frame(width: 150, height: 8)
            Text(String(format: "%+.2f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(firing ? Color.green : Color.secondary)
                .frame(width: 40, alignment: .leading)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .accessibilityValue(firing ? "past the deadzone" : "inside the deadzone")
    }

    private var meter: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let s = sides
            let pos = s.positive.map { min(half, CGFloat($0 / scale) * half) } ?? 0
            let neg = s.negative.map { min(half, CGFloat($0 / scale) * half) } ?? 0
            let clamped = max(-1, min(1, value / scale))
            let fill = abs(CGFloat(clamped)) * half
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.12))
                // The half no row listens to is dimmed further.
                if s.positive == nil || s.negative == nil {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: half)
                        .offset(x: s.positive == nil ? half : 0)
                }
                // Deadzone band, out to each side's first row.
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: (s.negative == nil ? pos : neg) + (s.positive == nil ? neg : pos))
                    .offset(x: half - (s.negative == nil ? pos : neg))
                Rectangle()
                    .fill(firing ? Color.green : Color.accentColor.opacity(0.8))
                    .frame(width: fill)
                    .offset(x: clamped >= 0 ? half : half - fill)
                Rectangle()
                    .fill(Color.primary.opacity(0.4))
                    .frame(width: 1)
                    .offset(x: half)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

private struct MotionWidget: View {
    let state: ControllerState
    /// Integrated angles passed in from the parent (VirtualControllerView)
    /// where the single stable Timer lives. We don't run the integrator
    /// here because this view is recreated on every 30 Hz tick of the
    /// outer TimelineView, which kept tearing down Timer subscriptions
    /// and freezing the model after the first sample.
    let integratedRoll: Float
    let integratedPitch: Float
    let integratedYaw: Float

    var body: some View {
        // Prefer real attitude when the controller reports it; fall back
        // to the parent's integrated gyro angles so the model still shows
        // live motion on controllers where Apple's sensor fusion isn't
        // running.
        let rawRoll  = (state.motion[.rollAngle]  ?? 0) * .pi
        let rawPitch = (state.motion[.pitchAngle] ?? 0) * (.pi / 2)
        let rawYaw   = (state.motion[.yawAngle]   ?? 0) * .pi
        // Each angle is chosen on its own. Pitch arrives fused for every
        // pad with an accelerometer, and one test across all three read
        // that as "has attitude", so roll and yaw showed a flat zero on
        // pads without Apple's attitude.
        let roll  = abs(rawRoll)  > 0.0001 ? rawRoll  : integratedRoll
        let pitch = state.motion[.pitchAngle] != nil ? rawPitch : integratedPitch
        let yaw   = abs(rawYaw)   > 0.0001 ? rawYaw   : integratedYaw

        return GyroVisualizationView(
            gyroX: state.motion[.gyroX] ?? 0,
            gyroY: state.motion[.gyroY] ?? 0,
            gyroZ: state.motion[.gyroZ] ?? 0,
            rollAngle: roll,
            pitchAngle: pitch,
            yawAngle: yaw,
            mode: .compact,
            // A picture, not a live SceneKit view: the zoomed map is drawn
            // as one picture (SharpZoom), which cannot hold an AppKit view.
            modelAsImage: true
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Motion")
        .accessibilityValue("Roll \(SpokenLive.degrees(roll)), pitch \(SpokenLive.degrees(pitch)), yaw \(SpokenLive.degrees(yaw)) degrees")
    }
}

// MARK: - MIDI Instrument layout

/// The MIDI template for the Live Visualizer: a full instrument panel that
/// renders inside the same box, picker, and zoom chrome as the controller
/// layouts. Selected from the template picker like any other layout and
/// chosen automatically for slots whose bindings are mostly MIDI, so MIDI
/// presets get it by default.
///
/// What it shows, per connected device (or one resting panel with nothing
/// connected):
///
///   • Seven-octave velocity-shaded keyboard - held notes glow with press
///     strength, bound notes carry a dot, octaves are labeled
///   • A dial for every bound CC (at rest until touched) plus every CC the
///     hardware has sent, with standard controller names (Mod Wheel,
///     Cutoff, Sustain...), knob-mode badges, and the freshest knob lit
///   • Pitch bend and aftertouch meters, the last Program Change, and a
///     16-slot channel activity strip
///   • A rolling event log (notes with velocity, sparse CC sweeps, program
///     changes) plus the session's total event count
///
/// Every key and knob opens the binding inspector with jump-to-editor.
/// Render discipline: state only mutates when the service's event counter
/// or device list actually changed, so an idle instrument costs one lock
/// per tick and zero re-renders.
struct MIDIInstrumentView: View {
    @Environment(\.visualizerSuspended) private var suspended
    let preset: Preset
    let slot: Int
    var onJump: ((EditorJumpTarget) -> Void)?

    @State private var snapshot: [MIDIInputService.DeviceActivity] = []
    @State private var lastCounter: UInt64 = 0
    @State private var deviceSignature: String = ""
    @State private var openInspector: String?
    @State private var stripWidthEstimate: CGFloat = 600

    /// Keyboard strip range: C0...C8, seven octaves.
    private static let lowNote = 24, highNote = 108
    private static let maxKnobs = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.isEmpty {
                devicePanel(placeholderDevice)
            } else {
                ForEach(snapshot) { device in
                    devicePanel(device)
                }
            }
        }
        .onAppear {
            // Live even while the preset is inactive, so the user can watch
            // their gear before flipping the engine on.
            MIDIInputService.shared.start()
            refresh(force: true)
        }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            // Paused while another app is in front and this window is
            // covered. Kept live when it is still on screen: the usual setup
            // is this window beside a DAW, playing with the DAW in front.
            guard !suspended, NSApp.isActive
                    || MenuBarController.mainWindow?.occlusionState.contains(.visible) == true else { return }
            refresh(force: false)
        }
        // Under the editor it stops; back in view it catches up at once.
        .onChange(of: suspended) { _, now in if !now { refresh(force: true) } }
    }

    private var placeholderDevice: MIDIInputService.DeviceActivity {
        MIDIInputService.DeviceActivity(
            id: "placeholder", name: "MIDI",
            notesDown: [], ccs: [], pitchBend: nil, aftertouch: nil,
            lastProgram: nil, velocities: [:], channelStamps: [:],
            recent: [], eventCount: 0)
    }

    private func refresh(force: Bool) {
        let counter = MIDIInputService.shared.activityCounter()
        let devices = MIDIInputService.shared.connectedDevices()
        let signature = devices.map(\.id).joined(separator: ",")
        guard force || counter != lastCounter || signature != deviceSignature else { return }
        lastCounter = counter
        deviceSignature = signature
        snapshot = MIDIInputService.shared.activitySnapshot()
    }

    /// Standard General MIDI controller names for the knob labels.
    static func ccName(_ cc: Int) -> String? {
        switch cc {
        case 0: return "Bank"
        case 1: return "Mod Wheel"
        case 2: return "Breath"
        case 4: return "Foot"
        case 5: return "Porta Time"
        case 7: return "Volume"
        case 8: return "Balance"
        case 10: return "Pan"
        case 11: return "Expression"
        case 64: return "Sustain"
        case 65: return "Portamento"
        case 66: return "Sostenuto"
        case 67: return "Soft Pedal"
        case 71: return "Resonance"
        case 72: return "Release"
        case 73: return "Attack"
        case 74: return "Cutoff"
        case 84: return "Porta Ctl"
        case 91: return "Reverb"
        case 93: return "Chorus"
        case 120: return "All Sound Off"
        case 123: return "All Notes Off"
        default: return nil
        }
    }

    // MARK: Device panel

    @ViewBuilder
    private func devicePanel(_ device: MIDIInputService.DeviceActivity) -> some View {
        let isPlaceholder = device.id == "placeholder"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "pianokeys")
                    .font(.caption)
                    .foregroundStyle(.pink)
                Text(isPlaceholder
                     ? "No MIDI device connected. Plug one in and this goes live"
                     : device.name)
                    .font(.caption.weight(isPlaceholder ? .regular : .semibold))
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
                Spacer()
                if let program = device.lastProgram {
                    Text("Program \(program)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.pink.opacity(0.14)))
                }
                if !device.notesDown.isEmpty {
                    Text(device.notesDown.sorted().map { MIDIService.noteName($0) }.joined(separator: " "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.pink)
                        .lineLimit(1)
                }
            }

            keyboardStrip(device)
            knobRow(device)

            HStack(alignment: .top, spacing: 14) {
                bendWidget(device)
                aftertouchWidget(device)
                channelStrip(device)
                Spacer(minLength: 0)
            }

            if !device.recent.isEmpty {
                eventLog(device)
            }
        }
    }

    // MARK: Keyboard strip

    private func boundNotes(deviceID: String) -> Set<Int> {
        var bound: Set<Int> = []
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .note {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                bound.insert(binding.input.index)
            }
        }
        return bound
    }

    private static func isBlackKey(_ note: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(note % 12)
    }

    @ViewBuilder
    private func keyboardStrip(_ device: MIDIInputService.DeviceActivity) -> some View {
        let bound = boundNotes(deviceID: device.id)
        let held = device.notesDown
        let velocities = device.velocities
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
                let whiteW = size.width / CGFloat(whites.count)
                for (i, note) in whites.enumerated() {
                    let rect = CGRect(x: CGFloat(i) * whiteW, y: 0,
                                      width: whiteW - 1, height: size.height)
                    let path = Path(roundedRect: rect, cornerRadius: 1.5)
                    if held.contains(note) {
                        // Velocity shading: soft touches glow lighter.
                        let vel = Double(velocities[note] ?? 100) / 127.0
                        context.fill(path, with: .color(.pink.opacity(0.45 + 0.55 * vel)))
                    } else {
                        context.fill(path, with: .color(.secondary.opacity(0.22)))
                    }
                    if bound.contains(note) {
                        let dot = CGRect(x: rect.midX - 1.5, y: size.height - 6,
                                         width: 3, height: 3)
                        context.fill(Path(ellipseIn: dot),
                                     with: .color(held.contains(note) ? .white : .pink))
                    }
                }
                var whiteIndex = 0
                for note in Self.lowNote...Self.highNote {
                    if Self.isBlackKey(note) {
                        let x = CGFloat(whiteIndex) * whiteW - whiteW * 0.3
                        let rect = CGRect(x: x, y: 0,
                                          width: whiteW * 0.6, height: size.height * 0.6)
                        let path = Path(roundedRect: rect, cornerRadius: 1.5)
                        if held.contains(note) {
                            let vel = Double(velocities[note] ?? 100) / 127.0
                            context.fill(path, with: .color(.pink.opacity(0.45 + 0.55 * vel)))
                        } else {
                            context.fill(path, with: .color(.primary.opacity(0.55)))
                        }
                        if bound.contains(note) {
                            let dot = CGRect(x: rect.midX - 1.5, y: rect.maxY - 5,
                                             width: 3, height: 3)
                            context.fill(Path(ellipseIn: dot),
                                         with: .color(held.contains(note) ? .white : .pink))
                        }
                    } else {
                        whiteIndex += 1
                    }
                }
            }
            .frame(height: 44)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { stripWidthEstimate = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in stripWidthEstimate = w }
            })
            .contentShape(Rectangle())
            .onTapGesture { location in
                openInspector = "keys-\(device.id)-\(noteAt(location: location))"
            }
            .popover(isPresented: inspectorPresented(prefix: "keys-\(device.id)-")) {
                if let key = openInspector,
                   let note = Int(key.split(separator: "-").last ?? "") {
                    midiInspector(title: "\(MIDIService.noteName(note)) (note \(note))",
                                  kind: .note, number: note, device: device)
                }
            }
            .help("Keys glow with press strength. A dot marks a bound note. Click a key to see its bindings.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Keyboard")
            .accessibilityValue(held.isEmpty
                ? "No keys held. \(bound.count) bound note\(bound.count == 1 ? "" : "s")"
                : "Held: " + held.sorted().map { MIDIService.noteName($0) }.joined(separator: ", "))
            .accessibilityAddTraits(.updatesFrequently)

            // Octave labels under every C.
            HStack(spacing: 0) {
                let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
                ForEach(whites, id: \.self) { note in
                    Text(note % 12 == 0 ? MIDIService.noteName(note) : "")
                        .font(.system(size: 7, weight: .medium).monospaced())
                        .foregroundStyle(.hint)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func noteAt(location: CGPoint) -> Int {
        let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
        // Black keys sit over the top 60 percent of the strip, drawn as in
        // the Canvas above; a click there picks the black key, which could
        // not be inspected when only white keys were hit-tested.
        let whiteW = max(1, stripWidthEstimate) / CGFloat(whites.count)
        if location.y < 44 * 0.6 {
            var whiteIndex = 0
            for note in Self.lowNote...Self.highNote {
                if Self.isBlackKey(note) {
                    let x = CGFloat(whiteIndex) * whiteW - whiteW * 0.3
                    if location.x >= x && location.x <= x + whiteW * 0.6 { return note }
                } else {
                    whiteIndex += 1
                }
            }
        }
        let fraction = max(0, min(0.999, location.x / max(1, stripWidthEstimate)))
        let index = Int(fraction * CGFloat(whites.count))
        return whites[min(index, whites.count - 1)]
    }

    // MARK: Knob row

    private func boundCCs(deviceID: String) -> [Int] {
        var found = Set<Int>()
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .cc {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                found.insert(binding.input.index)
            }
        }
        return found.sorted()
    }

    private func ccBadge(cc: Int, deviceID: String) -> (label: String, color: Color)? {
        for group in preset.joysticks {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == .cc
                && binding.input.index == cc {
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                if binding.outputs.contains(where: { $0.type == .absoluteVolume }) {
                    return ("Fader", .teal)
                }
                switch binding.input.midiCCMode {
                case .centered: return ("Dial", .orange)
                case .relative: return ("Turn", .indigo)
                default: return ("Switch", .secondary)
                }
            }
        }
        return nil
    }

    @ViewBuilder
    private func knobRow(_ device: MIDIInputService.DeviceActivity) -> some View {
        // Bound CCs always show, live or at rest, so the panel mirrors the
        // preset before anything is touched; CCs the hardware has sent but
        // the preset doesn't bind follow, most recently moved first.
        let bound = boundCCs(deviceID: device.id)
        let seenByCC = Dictionary(device.ccs.map { ($0.cc, $0) },
                                  uniquingKeysWith: { a, b in a.stamp > b.stamp ? a : b })
        let boundKnobs: [MIDIInputService.CCActivity] = bound.map { cc in
            seenByCC[cc] ?? MIDIInputService.CCActivity(
                deviceID: device.id, channel: 1, cc: cc, value: 0, stamp: 0)
        }
        let extras = device.ccs.filter { !bound.contains($0.cc) }
        let knobs = Array((boundKnobs + extras).prefix(Self.maxKnobs))
        if knobs.isEmpty {
            Text("Twist a knob or move a slider: every control appears here live.")
                .font(.caption2)
                .foregroundStyle(.hint)
        } else {
            let newest = knobs.map(\.stamp).max() ?? 0
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(knobs) { knob in
                        knobWidget(knob,
                                   isNewest: newest > 0 && knob.stamp == newest,
                                   device: device)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func knobWidget(_ knob: MIDIInputService.CCActivity, isNewest: Bool,
                            device: MIDIInputService.DeviceActivity) -> some View {
        let badge = ccBadge(cc: knob.cc, deviceID: device.id)
        let fraction = Double(knob.value) / 127.0
        Button {
            openInspector = "cc-\(device.id)-\(knob.cc)"
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .trim(from: 0.125, to: 0.875)
                        .stroke(Color.secondary.opacity(0.25),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(90))
                    Circle()
                        .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                        .stroke(isNewest ? Color.pink : Color.secondary.opacity(0.75),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(90))
                    Text(knob.stamp == 0 ? "-" : "\(knob.value)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isNewest ? .primary : .secondary)
                }
                .frame(width: 36, height: 36)
                Text("CC \(knob.cc)")
                    .font(.system(size: 8, weight: .medium).monospaced())
                    .foregroundStyle(.secondary)
                if let name = Self.ccName(knob.cc) {
                    Text(name)
                        .font(.system(size: 7.5))
                        .foregroundStyle(.hint)
                        .lineLimit(1)
                }
                if let badge {
                    Text(badge.label)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(badge.color.opacity(0.14)))
                }
            }
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .popover(isPresented: inspectorPresented(exact: "cc-\(device.id)-\(knob.cc)")) {
            midiInspector(title: ccTitle(knob.cc), kind: .cc, number: knob.cc, device: device)
        }
        .help("Control Change \(knob.cc)\(Self.ccName(knob.cc).map { " (\($0))" } ?? ""), value \(knob.stamp == 0 ? "not seen yet" : String(knob.value)). Click to see its bindings.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ccTitle(knob.cc).replacingOccurrences(of: " · ", with: ", ")
                            + (badge.map { ", bound as \($0.label)" } ?? ""))
        .accessibilityValue(knob.stamp == 0 ? "not seen yet" : "\(knob.value) of 127")
        .accessibilityHint("Inspects bindings for this control")
        .accessibilityAddTraits(.isButton)
    }

    private func ccTitle(_ cc: Int) -> String {
        if let name = Self.ccName(cc) { return "CC \(cc) · \(name)" }
        return "CC \(cc)"
    }

    // MARK: Meters

    @ViewBuilder
    private func bendWidget(_ device: MIDIInputService.DeviceActivity) -> some View {
        let bend = device.pitchBend ?? 0
        Button {
            openInspector = "bend-\(device.id)"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pitch Bend")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                        .frame(width: 90, height: 6)
                    Rectangle().fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 10)
                        .offset(x: 45)
                    Circle()
                        .fill(abs(bend) > 0.01 ? Color.pink : Color.secondary)
                        .frame(width: 10, height: 10)
                        .offset(x: 40 + CGFloat(bend) * 45)
                }
                .frame(height: 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pitch Bend")
        .accessibilityValue(abs(bend) < 0.01 ? "centered" : "\(Int((bend * 100).rounded())) percent")
        .accessibilityHint("Inspects bindings for this control")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: inspectorPresented(exact: "bend-\(device.id)")) {
            midiInspector(title: "Pitch Bend", kind: .pitchBend, number: nil, device: device)
        }
    }

    @ViewBuilder
    private func aftertouchWidget(_ device: MIDIInputService.DeviceActivity) -> some View {
        let touch = device.aftertouch ?? 0
        Button {
            openInspector = "touch-\(device.id)"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aftertouch")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                        .frame(width: 60, height: 6)
                    Capsule()
                        .fill(touch > 0 ? Color.pink : Color.clear)
                        .frame(width: max(0, 60 * CGFloat(touch) / 127), height: 6)
                }
                .frame(height: 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aftertouch")
        .accessibilityValue("\(touch) of 127")
        .accessibilityHint("Inspects bindings for this control")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: inspectorPresented(exact: "touch-\(device.id)")) {
            midiInspector(title: "Aftertouch", kind: .aftertouch, number: nil, device: device)
        }
    }

    /// Sixteen channel slots; ones this device has spoken on fill in, and
    /// the freshest is highlighted.
    @ViewBuilder
    private func channelStrip(_ device: MIDIInputService.DeviceActivity) -> some View {
        let freshest = device.channelStamps.max(by: { $0.value < $1.value })?.key
        VStack(alignment: .leading, spacing: 2) {
            Text("Channels")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...16, id: \.self) { channel in
                    let seen = device.channelStamps[channel] != nil
                    Circle()
                        .fill(channel == freshest ? Color.pink
                              : seen ? Color.secondary.opacity(0.6)
                              : Color.secondary.opacity(0.15))
                        .frame(width: 6, height: 6)
                        .help("Channel \(channel)\(seen ? "" : " - no messages yet")")
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Channels")
        .accessibilityValue(device.channelStamps.isEmpty
            ? "No messages yet"
            : "Heard on " + device.channelStamps.keys.sorted().map(String.init).joined(separator: ", ")
                + (freshest.map { ", latest \($0)" } ?? ""))
    }

    // MARK: Event log

    @ViewBuilder
    private func eventLog(_ device: MIDIInputService.DeviceActivity) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(device.recent.prefix(4).enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 8.5).monospaced())
                        .foregroundStyle(index == 0 ? Color.secondary : Color.secondary.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if device.eventCount > 0 {
                Text("\(device.eventCount) events")
                    .font(.system(size: 8.5).monospaced())
                    .foregroundStyle(.hint)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Inspector

    private func inspectorPresented(exact: String) -> Binding<Bool> {
        Binding(get: { openInspector == exact },
                set: { if !$0 { openInspector = nil } })
    }

    private func inspectorPresented(prefix: String) -> Binding<Bool> {
        Binding(get: { openInspector?.hasPrefix(prefix) == true },
                set: { if !$0 { openInspector = nil } })
    }

    private struct MIDIBindingMatch: Identifiable {
        let id: UUID
        let joystickIndex: Int
        let binding: BindingModel
    }

    private func matches(kind: MIDIInputKind, number: Int?, deviceID: String) -> [MIDIBindingMatch] {
        var found: [MIDIBindingMatch] = []
        for (joystickIndex, group) in preset.joysticks.enumerated() {
            for binding in group.bindings
            where binding.input.type == .midi && binding.input.midiKind == kind {
                if let number, binding.input.index != number { continue }
                if let filter = binding.input.midiDeviceID, filter != deviceID { continue }
                found.append(MIDIBindingMatch(id: binding.id,
                                              joystickIndex: joystickIndex,
                                              binding: binding))
            }
        }
        return found
    }

    @ViewBuilder
    private func midiInspector(title: String, kind: MIDIInputKind, number: Int?,
                               device: MIDIInputService.DeviceActivity) -> some View {
        let matchingBindings = matches(kind: kind, number: number, deviceID: device.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Spacer()
                if !matchingBindings.isEmpty {
                    Text("\(matchingBindings.count) bound")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if matchingBindings.isEmpty {
                Text("No bindings in this preset target this input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matchingBindings) { match in
                    Button {
                        openInspector = nil
                        // The row itself, so a second row on the same input
                        // opens that row; after the popover has closed.
                        let target = EditorJumpTarget(joystickIndex: match.joystickIndex,
                                                      inputSerialized: match.binding.input.serialized,
                                                      bindingID: match.binding.id)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { onJump?(target) }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.binding.input.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(match.binding.outputs.map(\.displayName).joined(separator: " + "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.forward.circle")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 230, alignment: .leading)
    }
}


/// Edit Layout, Reset (while editing), and the zoom for one visualizer,
/// drawn by the host on the Live Visualizer title row.
struct VisualizerHeaderControls: View {
    @ObservedObject var control: VisualizerControlState

    var body: some View {
        HStack(spacing: 10) {
            Button {
                control.editMode.toggle()
            } label: {
                Label(control.editMode ? "Done Editing" : "Edit Layout",
                      systemImage: control.editMode ? "checkmark.circle.fill" : "pencil.and.outline")
            }
            .buttonStyle(SolidButton(tint: control.editMode ? .green : .blue, size: .compact))
            .disabled(control.showingModel && !control.editMode)
            .help(control.showingModel ? "The controller is drawn as it is built, so its controls stay in place"
                  : (control.editMode ? "Finish customizing" : "Drag widgets to rearrange the layout"))
            .spotlightAnchor(SpotlightID.customizeButton)

            if control.editMode {
                Button {
                    control.resetToken += 1
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondary)
                .help("Reset all widgets to their default position")
            }

            // Zoom: minus, slider, plus. Kept with the map's position for
            // each preset and group (see VirtualControllerView.saveView).
            HStack(spacing: 4) {
                Button {
                    control.scale = max(0.3, control.scale - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .help("Shrink visualizer")
                .accessibilityLabel("Shrink visualizer")

                Slider(value: $control.scale, in: 0.3...1.5)
                    .frame(width: 80)
                    .help("Resize the live visualizer content")
                    .accessibilityLabel("Visualizer size")
                    .accessibilityValue(String(format: "%.0f percent", control.scale * 100))

                Button {
                    control.scale = min(1.5, control.scale + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .help("Enlarge visualizer")
                .accessibilityLabel("Enlarge visualizer")
            }
        }
    }
}


/// Color for a region's palette index, shared by every region map.
func regionPaletteColor(at index: Int) -> Color {
    let palette = TouchpadRegion.colorPalette
    let safe = max(0, min(palette.count - 1, index))
    switch palette[safe] {
    case "red":    return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green":  return .green
    case "mint":   return .mint
    case "teal":   return .teal
    case "cyan":   return .cyan
    case "blue":   return .blue
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink":   return .pink
    case "brown":  return .brown
    default:       return .gray
    }
}

/// A surface with regions drawn on it and a live point moving over it:
/// the screen for cursor regions, a stick's travel for stick regions.
/// A region the point is inside lights up, the same way a pressed
/// touchpad zone does, so the map reads without the preset running.
struct RegionMapView: View {
    let title: String
    let systemImage: String
    /// Width divided by height of the surface being drawn.
    let aspect: CGFloat
    let regions: [TouchpadRegion]
    /// Live position on the surface, 0...1 in both axes.
    let point: CGPoint
    let pointLabel: String
    /// The screen map follows the real pointer: it observes the cursor
    /// service and keeps its sampling alive while the map is on screen.
    var liveCursor: Bool = false
    /// The screen map shows this display rather than the pointer's when
    /// set: its shape, its regions, and the pointer only while it is there.
    var displayOverride: DisplayKey? = nil
    /// The Screen template's map: wider and taller than the side maps.
    var large: Bool = false
    /// Clicking a region goes to the row that binds it, the same as
    /// clicking a button on the controller map. Nil leaves the map
    /// read-only.
    var onPick: ((TouchpadRegion) -> Void)?
    /// Wraps a region in the visualizer's inspector, the popover that lists
    /// its rows with a way to each and to the region's editor. Used in place
    /// of `onPick` when set.
    var inspect: ((TouchpadRegion, AnyView) -> AnyView)? = nil

    private var cursorService: CursorRegionService { CursorRegionService.shared }
    @Environment(\.visualizerSuspended) private var suspended
    @State private var tracking = false

    private func setTracking(_ on: Bool) {
        guard on != tracking else { return }
        tracking = on
        if on { cursorService.beginTracking() } else { cursorService.endTracking() }
    }

    private var livePoint: CGPoint { liveCursor ? cursorService.cursorNormalized : point }

    /// The display the map represents.
    private var shownDisplay: DisplayKey? { displayOverride ?? cursorService.currentDisplay }
    /// Whether the pointer is on the display the map represents.
    private var pointerIsHere: Bool {
        !liveCursor || displayOverride == nil || displayOverride == cursorService.currentDisplay
    }

    /// The screen map is drawn in the shape of the display the pointer is
    /// actually on. Drawn at a fixed 16:10 it lied on every other display:
    /// a region that covers the right third of an ultrawide was drawn as a
    /// much taller box than the one it fires in.
    private var drawnAspect: CGFloat {
        guard liveCursor else { return aspect }
        let live = cursorService.aspect(of: displayOverride) ?? cursorService.currentScreenAspect
        return max(0.5, min(4.0, live))
    }

    /// What the map is showing: the display name, and a note when there is
    /// more than one, because these regions follow the pointer onto any
    /// display rather than belonging to one of them.
    private var subtitle: String? {
        guard liveCursor else { return nil }
        let name = shownDisplay?.name ?? cursorService.currentScreenName
        guard !name.isEmpty else { return nil }
        let here = regions.filter { cursorService.regionApplies($0, on: shownDisplay) }.count
        if here < regions.count {
            return "\(name): \(here) of \(regions.count) regions apply here"
        }
        let perDisplay = regions.contains { $0.display != nil }
        return cursorService.screenCount > 1 && !perDisplay
            ? "\(name), and every other display"
            : name
    }

    private var inside: Set<UUID> {
        guard pointerIsHere else { return [] }
        let p = livePoint
        return Set(regions.filter { applies($0) && $0.contains(normalizedX: p.x, y: p.y) }.map(\.id))
    }

    /// Whether the region counts on the display the map is showing. Only
    /// the screen map distinguishes: a stick or pad zone always applies.
    private func applies(_ region: TouchpadRegion) -> Bool {
        !liveCursor || cursorService.regionApplies(region, on: shownDisplay)
    }

    // Observes the cursor only while it draws it live: a stick or touchpad
    // zone map, or a map under the editor, does not redraw on every
    // pointer move.
    var body: some View {
        if liveCursor && !suspended { CursorRegionObserver { mapBody } } else { mapBody }
    }

    @ViewBuilder
    private var mapBody: some View {
        let hot = inside
        let point = livePoint
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if !title.isEmpty {
                    HStack {
                        Label(title, systemImage: systemImage)
                            .font(.callout.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(regions.count) region\(regions.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.hint)
                        .lineLimit(1)
                }
            }
            GeometryReader { geo in
                // Fit inside the box rather than deriving height from width
                // alone: a 16:10 display at the full width came out taller
                // than the frame, so the bottom of the map, and any region
                // living there, was clipped away.
                let h = min(geo.size.height, geo.size.width / drawnAspect)
                let w = h * drawnAspect
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.22))
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    // Center lines, so a stick's neutral and a screen's
                    // middle are obvious.
                    Path { p in
                        p.move(to: CGPoint(x: w / 2, y: 4)); p.addLine(to: CGPoint(x: w / 2, y: h - 4))
                        p.move(to: CGPoint(x: 6, y: h / 2)); p.addLine(to: CGPoint(x: w - 6, y: h / 2))
                    }
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)

                    ForEach(regions) { region in
                        let lit = hot.contains(region.id)
                        // A region for another display is drawn faint, so
                        // it is visible but clearly not live here.
                        let here = applies(region)
                        let color = regionPaletteColor(at: region.colorIndex).opacity(here ? 1 : 0.35)
                        let rect = CGRect(x: region.minX * w, y: region.minY * h,
                                          width: (region.maxX - region.minX) * w,
                                          height: (region.maxY - region.minY) * h)
                        let swatch = RoundedRectangle(cornerRadius: 4)
                            .fill(color.opacity(lit ? 0.55 : 0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(color.opacity(lit ? 1 : 0.5), lineWidth: lit ? 2 : 1)
                            )
                            .overlay(
                                // A small corner region has no room for its
                                // name; the color and the tooltip carry it.
                                Group {
                                    if rect.width >= 42 && rect.height >= 18 {
                                        Text(region.name)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(lit ? .white : .secondary)
                                            .lineLimit(1)
                                            .padding(.horizontal, 2)
                                    }
                                }
                            )
                            .frame(width: max(8, rect.width), height: max(8, rect.height))
                        Group {
                            if let inspect {
                                inspect(region, AnyView(swatch.accessibilityLabel(region.name)))
                                    .help("\(region.name). Click to see its rows.")
                            } else if let onPick {
                                Button { onPick(region) } label: { swatch }
                                    .buttonStyle(.plain)
                                    .help("\(region.name). Click to go to its row.")
                            } else {
                                swatch.help(region.name)
                            }
                        }
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.easeOut(duration: 0.12), value: lit)
                    }

                    // The live point, only while the pointer is on this display.
                    if pointerIsHere {
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 8, height: 8)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .position(x: min(max(0, point.x), 1) * w,
                                      y: min(max(0, point.y), 1) * h)
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Centered in whatever space is left over once it is fitted.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .frame(height: large ? 300 : (drawnAspect > 1.2 ? 170 : 200))
            .frame(maxWidth: large ? 520 : (drawnAspect > 1.2 ? 320 : 220))
            // Its own hold on the cursor sampler, let go under the editor.
            .onAppear { setTracking(liveCursor && !suspended) }
            .onDisappear { setTracking(false) }
            .onChange(of: suspended) { _, now in setTracking(liveCursor && !now) }
            // Clickable regions stay reachable with VoiceOver.
            .accessibilityElement(children: inspect != nil ? .contain : .ignore)
            .accessibilityLabel(title.isEmpty ? "Screen regions" : title)
            .accessibilityValue(hot.isEmpty
                                ? "\(pointLabel) outside every region"
                                : "\(pointLabel) inside \(regions.filter { hot.contains($0.id) }.map(\.name).joined(separator: ", "))")
        }
        .padding(.top, 4)
    }
}


/// What a knock on the Mac does in this preset, and which gesture just
/// landed. Lights the matching chip for a moment, the way a pressed button
/// lights on the controller map.
struct TapMapView: View {
    @State private var sensorReason = "visualizer-" + UUID().uuidString
    let counts: [Int]
    @ObservedObject private var activity = ChassisTapActivity.shared

    private static let names = ["", "Single", "Double", "Triple", "Quadruple", "Quintuple"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Taps on the Mac", systemImage: "hand.tap.fill")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("knock on the palm rest")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(counts, id: \.self) { count in
                    chip(count)
                }
            }
        }
        .padding(.top, 4)
        // Keep the sensor awake while the map is on screen, so a knock
        // lights a chip whether or not the preset is running.
        // A reason of its own per map: with one shared reason, the first map
        // to go away stopped the sensor under another still on screen.
        .onAppear { ChassisTapService.shared.retain(sensorReason) }
        .onDisappear { ChassisTapService.shared.release(sensorReason) }
    }

    /// One tap count as a chip that lights when that gesture fires.
    @ViewBuilder
    private func chip(_ count: Int) -> some View {
        let lit: Bool = activity.activeKeys.contains("cht \(count)")
        let fill: Color = lit ? Color.orange.opacity(0.75) : Color.secondary.opacity(0.12)
        let edge: Color = lit ? Color.orange : Color.secondary.opacity(0.3)
        let name: String = Self.names[min(5, count)]
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(lit ? Color.white : Color.secondary)
            Text(name)
                .font(.system(size: 9))
                .foregroundStyle(lit ? Color.white.opacity(0.9) : Color.secondary.opacity(0.7))
        }
        .frame(width: 62, height: 46)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(edge, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: lit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) tap")
        .accessibilityValue(lit ? "just fired" : "idle")
    }
}

/// Re-renders only its content when the Mac's keyboard or mouse input
/// changes, so the views around it do not.
/// Redraws its content as the pointer moves over a screen map.
private struct CursorRegionObserver<Content: View>: View {
    @ObservedObject private var cursorService = CursorRegionService.shared
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

private struct ExternalInputObserver<Content: View>: View {
    @Environment(\.visualizerSuspended) private var suspended
    @ViewBuilder let content: () -> Content
    // Under the editor the diagram is drawn once and not redrawn on every
    // key and pointer move the editor's own monitor sees.
    var body: some View {
        if suspended { content() } else { Live(content: content) }
    }

    private struct Live: View {
        @ObservedObject private var externalInput = ExternalInputDeviceService.shared
        let content: () -> Content
        var body: some View { content() }
    }
}

/// Set while the visualizer is covered (the binding editor's sheet), so its
/// live clock stops.
private struct VisualizerSuspendedKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var visualizerSuspended: Bool {
        get { self[VisualizerSuspendedKey.self] }
        set { self[VisualizerSuspendedKey.self] = newValue }
    }
}


/// Draws the zoomed Live Visualizer map as one picture at its final size
/// (see visualizerPanelContent).
private struct SharpZoom: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.drawingGroup() } else { content }
    }
}
