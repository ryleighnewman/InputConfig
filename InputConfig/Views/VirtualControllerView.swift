import SwiftUI

/// Spoken forms of live values, coarse on purpose. VoiceOver re-announces
/// a focused element every time its value changes, and these values
/// change 30 to 60 times a second; two-decimal precision meant a stick at
/// rest produced a continuous stream and the visualizer could not be used
/// with VoiceOver at all. Cardinal words and 25 percent steps change
/// rarely and say more.
enum SpokenLive {
    /// "right 50 percent", "centerd".
    static func stick(x: Float, y: Float) -> String {
        let mag = (x * x + y * y).squareRoot()
        guard mag > 0.15 else { return "centerd" }
        let step = Int((min(1, mag) * 4).rounded()) * 25
        var dir: [String] = []
        if y < -0.35 { dir.append("up") } else if y > 0.35 { dir.append("down") }
        if x < -0.35 { dir.append("left") } else if x > 0.35 { dir.append("right") }
        return "\(dir.isEmpty ? "off center" : dir.joined(separator: " ")) \(step) percent"
    }
    /// A single signed axis in quarter steps: "plus 50 percent", "centerd".
    static func axis(_ v: Float) -> String {
        let step = Int((min(1, abs(v)) * 4).rounded()) * 25
        guard step > 0 else { return "centerd" }
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
/// Tapping a widget opens a popover summarising any bindings in the
/// current preset that target that physical input, with a button to jump
/// into the preset editor focused on the relevant row.
/// The bits of a visualizer the host draws controls for (Edit Layout, the
/// zoom) outside the panel, on the Live Visualizer title row. One per
/// visualizer, owned by the host, observed by both.
final class VisualizerControlState: ObservableObject {
    @Published var editMode = false
    /// The size the map is drawn at. Fixed: the zoom control was removed
    /// because the map is laid out to fit the panel already. Still a
    /// property so the value is in one place if the control comes back.
    @Published var scale: Double = 1.0
    /// Bumped by the host's Reset button; the panel clears its offsets.
    @Published var resetToken = 0
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

    /// Grid line colour: white on the coloured papers, the neutral
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
    @ObservedObject private var cursorService = CursorRegionService.shared
    /// The Mac's own keyboard and mouse. Observed so the keyboard and mouse
    /// templates redraw as keys and buttons go down, with no controller in
    /// the slot to drive the clock.
    @ObservedObject private var externalInput = ExternalInputDeviceService.shared
    /// This instance's name on the keyboard / mouse monitor. Unique per
    /// instance: when a preset changes, the old visualizer's disappear
    /// can run after the new one's appear, and a shared name let that
    /// late release wipe the new hold.
    @State private var externalHold = "visualizer-" + UUID().uuidString

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

    /// Optional callback: when the user picks a new layout template
    /// from the inline visualizer picker, this fires with the slot
    /// and the new `SlotInputKind`. Host updates the preset model
    /// via the store. nil hides the picker.
    var onChangeInputKind: ((Int, SlotInputKind) -> Void)?

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

    /// User-adjustable pan offset for the controller layout inside the
    /// panel. Lets the user drag the controller around when zoomed in.
    /// Reset to .zero when the user lowers zoom to 0.5 or less.
    @State private var panOffset: CGSize = .zero
    @State private var dragInProgress: CGSize = .zero

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
        let category = controllerService.controllerDetails[slot]?.productCategory ?? "Default"
        return "VirtualController.layout.\(category)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Edit Layout, the zoom, and the device name are drawn by the
            // host on the Live Visualizer title row (see
            // VisualizerHeaderControls), so the panel starts right here.

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
                                    paused: visualizerIdle || info == nil || !appIsActive)) { _ in
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
                guard info != nil else { return }
                let sig = Self.renderSignature(state)
                if sig != lastRenderSignature {
                    lastRenderSignature = sig
                    lastSignatureChangeAt = CACurrentMediaTime()
                    if visualizerIdle { visualizerIdle = false }
                } else if !visualizerIdle,
                          CACurrentMediaTime() - lastSignatureChangeAt > 0.7 {
                    visualizerIdle = true
                }
            }
            // Drag the panel around when zoomed in past column bounds.
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragInProgress = value.translation
                    }
                    .onEnded { value in
                        panOffset.width += value.translation.width
                        panOffset.height += value.translation.height
                        dragInProgress = .zero
                    }
            )

            if editMode {
                Text("Drag any widget to a new position. The layout saves automatically for this controller model.")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .padding(.top, 2)
            }
        }
        .onAppear {
            loadOffsets()
            controllerService.retainLiveInput("visualizer")
        }
        .onDisappear {
            controllerService.releaseLiveInput("visualizer")
            ExternalInputDeviceService.shared.release(externalHold)
        }
        // Hold the Mac's keyboard or mouse monitor open while that template
        // is up, so keys and clicks show live with nothing running.
        .task(id: effectiveInputKind) {
            ExternalInputDeviceService.shared.retain(externalHold,
                                                     mouse: effectiveInputKind == .mouse,
                                                     keyboard: effectiveInputKind == .keyboard)
        }
        .onChange(of: slot) { _, _ in
            loadOffsets()
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
            if s.motion[.pitchAngle] == nil { integratedPitch += gx * dt }
            integratedYaw   += gy * dt
            integratedRoll  += gz * dt
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
           let synthetic = controllerService.readControllerState(at: slot) {
            return synthetic
        }
        #endif
        return controllerService.currentStates[slot] ?? ControllerState()
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
        controllerService.controllerDetails[slot]
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
            if onChangeInputKind != nil { templatePicker }
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
                if info == nil && !slotHasAnyBinding {
                    emptyVisualizerPlaceholder
                } else if slotIsMacTapsOnly {
                    // Tap the Mac: the input is the computer itself, so a
                    // controller drawing here would be about nothing. The
                    // tap map below is the whole picture.
                    EmptyView()
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
                          })
        }
    }

    /// Everything a touch surface can be bound to in this preset: the
    /// finger axes, the physical press, every zone the preset defines, and
    /// the tap gestures. The inspector lists rows for all of them, so
    /// clicking the pad finds a zone or a two-finger tap row, which it
    /// could not before: only the axes and the press were listed.
    private var touchpadInspectEvents: [InputEvent] {
        var events: [InputEvent] = [
            .touchpad(finger: 0, axis: .x, direction: .positive),
            .touchpad(finger: 0, axis: .y, direction: .positive),
            .button(13)
        ]
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
            if preset.cursorRegions.isEmpty {
                Text("No screen regions in this preset yet. Add a Screen region row in the editor and draw its regions from the row's Options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Spacer(minLength: 0)
                    RegionMapView(title: "",
                                  systemImage: "rectangle.dashed",
                                  aspect: 16.0 / 10.0,
                                  regions: preset.cursorRegions,
                                  point: .zero,
                                  pointLabel: "Pointer",
                                  liveCursor: true,
                                  displayOverride: chosenScreenDisplay,
                                  large: true,
                                  onPick: { region in
                                      jumpToInput(InputEvent.cursorRegion(region.id))
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
                .foregroundStyle(.tertiary)
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
            Spacer(minLength: 0)
            if currentKind != .auto {
                Button("Reset to auto") { onChangeInputKind?(slot, .auto) }
                    .buttonStyle(.solidSecondaryCompact)
                    .controlSize(.small)
                    .help("Use the binding-type majority to pick the template automatically.")
            }
        }
        .padding(.horizontal, 4)
        .spotlightAnchor(SpotlightID.templatePicker)
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
                .foregroundStyle(.tertiary)
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
            switch b.input.extMouseKind ?? .button {
            case .button:
                out.insert("btn\(b.input.index)")
            case .moveX, .moveY:
                out.insert("move")
            case .scrollY:
                out.insert(b.input.axisDirection == .negative ? "scrollDown" : "scrollUp")
            case .scrollX:
                out.insert(b.input.axisDirection == .negative ? "scrollLeft" : "scrollRight")
            case .pressure:
                out.insert("pressure")
            case .deepPress:
                out.insert("deepPress")
            case .doubleClick:
                out.insert("doubleClick")
            case .scrollGesture:
                out.insert("scrollGesture")
            }
        }
        return out
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
        if !externalInput.accessibilityGranted {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Live keys and clicks need the Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
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
            KeyboardDiagramView(boundKeyCodes: bound, pressedKeyCodes: pressedKeyCodes)
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
            MouseDiagramView(pressedButtons: pressedMouseButtons,
                             activeKinds: activeMouseKinds,
                             boundKinds: boundKinds,
                             pressure: externalInput.trackpadPressure,
                             pressureStage: externalInput.trackpadPressureStage,
                             scrollGesture: externalInput.scrollGesture)
            Text("Force Touch is read only while InputConfig is the front window; everything else works from any app.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                inspectable(label: "Touchpad", events: touchpadInspectEvents) {
                    TouchpadWidget(pressed: (state.buttons[13] ?? 0) > 0.5,
                                   presetRegions: preset.touchpadRegions,
                                   surfaceAspect: touchpadSurfaceAspect)
                        .scaleEffect(1.5, anchor: .center)
                        // A scaleEffect leaves the layout box at the
                        // unscaled size, so a quarter of each dimension is
                        // added back by hand and the surrounding HStack
                        // measures what is actually visible. Derived from
                        // the pad's real height, which changes with the
                        // surface rather than always being 70.
                        .padding(.horizontal, 55)
                        .padding(.vertical, touchpadPadHeight / 4)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            if touchpadBindings == 0 {
                Text("No touchpad inputs bound for this slot. Scan a finger swipe or a touchpad region in the editor, or pick \"Apply default 1 to 16\" from the Touchpad Setup sheet for a starter grid.")
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
        return controllerService.effectiveSlot(for: preset.joysticks[slot], groupIndex: slot)
    }

    private var capabilities: ControllerScaffold.DeviceCapabilities {
        ControllerScaffold.capabilities(service: controllerService, slot: deviceSlot,
                                        inputKind: slot < preset.joysticks.count
                                            ? preset.joysticks[slot].inputKind : .auto,
                                        purpose: .mirror)
    }

    /// The names printed on the face and menu buttons, which differ by
    /// family: Cross / Circle / Square / Triangle on PlayStation, A / B / X
    /// / Y on Xbox and most others, and B / A / Y / X on a Switch pad,
    /// whose buttons sit in the opposite places.
    private var brandLabels: (face: [Int: String], menu: [Int: String], tint: [Int: Color]) {
        switch info?.brand ?? .unknown {
        case .dualSense, .dualShock4:
            // Sony's own glyph colours: cross blue, circle red, square pink,
            // triangle green.
            return ([0: "✕", 1: "○", 2: "□", 3: "△"],
                    [8: "Create", 10: "PS", 9: "Options"],
                    [0: Color(red: 0.45, green: 0.65, blue: 1.0), 1: .red, 2: .pink, 3: .green])
        case .switchPro, .joyConLeft, .joyConRight, .joyConPair:
            return ([0: "B", 1: "A", 2: "Y", 3: "X"],
                    [8: "Capture", 10: "Home", 9: "+"],
                    [0: .secondary, 1: .secondary, 2: .secondary, 3: .secondary])
        case .xbox:
            return ([0: "A", 1: "B", 2: "X", 3: "Y"],
                    [8: "View", 10: "Xbox", 9: "Menu"],
                    [0: .green, 1: .red, 2: .blue, 3: .yellow])
        default:
            return ([0: "A", 1: "B", 2: "X", 3: "Y"],
                    [8: "Share", 10: "Home", 9: "Menu"],
                    [0: .green, 1: .red, 2: .blue, 3: .yellow])
        }
    }

    @ViewBuilder
    private var controllerWidgets: some View {
        var caps = capabilities
        let labels = brandLabels
        // Safety net: anything the controller is actually sending is drawn,
        // whatever the capability read said. A control that fires but is
        // not on screen is the worst possible outcome here.
        let _ = {
            let st = state
            if st.hats[0] != nil { caps.dpad = true }
            if (st.axes[4] ?? 0) != 0 || (st.axes[5] ?? 0) != 0 { caps.triggers = true }
            for index in st.buttons.keys where !caps.buttons.contains(where: { $0.index == index }) {
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
                            inspectable(label: "LT", events: [.axis(4, direction: .positive)]) {
                                TriggerWidget(label: "LT", value: state.axes[4] ?? 0,
                                              threshold: thresholdForAxis(4, dir: .positive),
                                              tint: .blue)
                            }
                        }
                        if caps.buttons.contains(where: { $0.index == 4 }) {
                            inspectable(label: "LB", events: [.button(4)]) {
                                ShoulderWidget(label: "LB", pressed: (state.buttons[4] ?? 0) > 0.5)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            ForEach([8, 10, 9], id: \.self) { index in
                                if caps.buttons.contains(where: { $0.index == index }) {
                                    menuPill(label: labels.menu[index] ?? "Menu", index: index)
                                }
                            }
                        }
                        if caps.gyro { motionWidgetIfAvailable }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        if caps.triggers {
                            inspectable(label: "RT", events: [.axis(5, direction: .positive)]) {
                                TriggerWidget(label: "RT", value: state.axes[5] ?? 0,
                                              threshold: thresholdForAxis(5, dir: .positive),
                                              tint: .red)
                            }
                        }
                        if caps.buttons.contains(where: { $0.index == 5 }) {
                            inspectable(label: "RB", events: [.button(5)]) {
                                ShoulderWidget(label: "RB", pressed: (state.buttons[5] ?? 0) > 0.5)
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
                        ]) {
                            DPadWidget(hat: state.hats[0] ?? (0, 0))
                        }
                    }
                    Spacer(minLength: 0)
                    if caps.sticks.count >= 2 {
                        HStack(spacing: 18) {
                            inspectable(label: "Left stick", events: [
                                .axis(0, direction: .positive), .axis(0, direction: .negative),
                                .axis(1, direction: .positive), .axis(1, direction: .negative),
                                .button(11)
                            ]) {
                                StickWidget(label: "Left stick",
                                            x: state.axes[0] ?? 0,
                                            y: state.axes[1] ?? 0,
                                            pressed: (state.buttons[11] ?? 0) > 0.5)
                            }
                            inspectable(label: "Right stick", events: [
                                .axis(2, direction: .positive), .axis(2, direction: .negative),
                                .axis(3, direction: .positive), .axis(3, direction: .negative),
                                .button(12)
                            ]) {
                                StickWidget(label: "Right stick",
                                            x: state.axes[2] ?? 0,
                                            y: state.axes[3] ?? 0,
                                            pressed: (state.buttons[12] ?? 0) > 0.5)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    ZStack {
                        if caps.buttons.contains(where: { $0.index == 3 }) {
                            faceButton(label: labels.face[3] ?? "Y", index: 3, tint: labels.tint[3] ?? .yellow).offset(y: -24)
                        }
                        if caps.buttons.contains(where: { $0.index == 0 }) {
                            faceButton(label: labels.face[0] ?? "A", index: 0, tint: labels.tint[0] ?? .green).offset(y: 24)
                        }
                        if caps.buttons.contains(where: { $0.index == 2 }) {
                            faceButton(label: labels.face[2] ?? "X", index: 2, tint: labels.tint[2] ?? .blue).offset(x: -24)
                        }
                        if caps.buttons.contains(where: { $0.index == 1 }) {
                            faceButton(label: labels.face[1] ?? "B", index: 1, tint: labels.tint[1] ?? .red).offset(x: 24)
                        }
                    }
                    .frame(width: 96, height: 96)
                }
            }

            // A device with a single stick (the PlayStation Access
            // Controller, some arcade and adaptive pads) gets that one,
            // centerd, rather than a phantom second stick.
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
            let extras = controllerService.extraButtonsSnapshot(for: slot)
                .filter { ![13].contains($0.index) }  // Touchpad has its own widget
            if caps.touchpad || !extras.isEmpty {
                HStack(alignment: .center, spacing: 16) {
                    if caps.touchpad {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(info?.name ?? "Controller") touchpad")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            inspectable(label: "Touchpad", events: touchpadInspectEvents) {
                                TouchpadWidget(pressed: (state.buttons[13] ?? 0) > 0.5,
                                               presetRegions: preset.touchpadRegions,
                                               surfaceAspect: touchpadSurfaceAspect)
                            }
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
            let extraAxes = controllerService.extraAxesSnapshot(for: slot)
            if !extraAxes.isEmpty {
                extraAxesWidget(axes: extraAxes)
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
                        .foregroundStyle(.tertiary)
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
        // Detected extras come in two flavours:
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
                    .accessibilityLabel("Extra buttons")
                    .accessibilityValue(namedExtrasAccessibilityValue(named))
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
    }

    /// Round placeholder icon for an unknown extra button. Shows the
    /// raw index in the center, flashes green while the button is held,
    /// and participates in the visualizer's "Customize layout" drag
    /// machinery via `inspectable()` so the user can reposition it.
    @ViewBuilder
    private func unknownButtonPlaceholder(
        _ button: GameControllerService.ExtraButton
    ) -> some View {
        inspectable(label: "extra-\(button.index)", events: [.button(button.index)]) {
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
            .help("Unknown extra button \(button.index) - drag in 'Customize layout' to reposition")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Extra button \(button.index)")
            .accessibilityValue(button.pressed ? "pressed" : "released")
        }
    }

    /// Clickable light-bar strip that mimics the real DualSense's top
    /// LED bar. Filled with the preset's chosen color when set, or a
    /// faint "click to set" placeholder otherwise. Tap to open the
    /// per-preset light bar picker in a popover anchored right here. The
    /// picker pushes the color to the controller live while the preset
    /// is active, so there is nothing to stop first.
    @ViewBuilder
    private var lightBarStripWidget: some View {
        Button {
            showLightBarPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "light.beacon.max.fill")
                    .font(.caption2)
                    .foregroundStyle(lightBarTint ?? .secondary)
                    .opacity(lightBarTint == nil ? 0.4 : 1)

                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                    if let tint = lightBarTint {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(
                                colors: [tint.opacity(0.85), tint, tint.opacity(0.85)],
                                startPoint: .leading, endPoint: .trailing))
                            .shadow(color: tint.opacity(0.7), radius: 5)
                    } else {
                        Text("Click to set color")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 220, maxHeight: 8)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(lightBarTint?.opacity(0.55) ?? Color.secondary.opacity(0.2),
                            lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help(lightBarTint == nil
              ? "Pick a light-bar color for this preset"
              : "Edit this preset's light-bar color")
        // The button has no text once a color is set: only the beacon
        // glyph, a swatch and a chevron. VoiceOver needs a name and the
        // colour spoken, not shown.
        .accessibilityLabel("Light bar colour")
        .accessibilityValue(lightBarTint == nil ? "not set" : "set")
        .accessibilityHint("Opens the light bar color picker")
        .spotlightAnchor(SpotlightID.lightBarStrip)
        .popover(isPresented: $showLightBarPopover, arrowEdge: .top) {
            trailing()
        }
    }

    @ViewBuilder
    private var motionWidgetIfAvailable: some View {
        if info?.supportsMotion == true {
            inspectable(label: "Motion", events: [
                .motion(.gyroY, direction: .positive),
                .motion(.gyroX, direction: .positive)
            ]) {
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
        label: String, events: [InputEvent],
        @ViewBuilder content: () -> Content
    ) -> some View {
        let persistedOffset = dragOffsets[label] ?? .zero
        let liveOffset: CGSize = (liveDrag?.label == label) ? liveDrag!.translation : .zero
        let totalOffset = CGSize(
            width: persistedOffset.width + liveOffset.width,
            height: persistedOffset.height + liveOffset.height
        )

        if editMode {
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
                            liveDrag = (label, value.translation)
                        }
                        .onEnded { value in
                            let base = dragOffsets[label] ?? .zero
                            dragOffsets[label] = CGSize(
                                width: base.width + value.translation.width,
                                height: base.height + value.translation.height
                            )
                            liveDrag = nil
                            persistOffsets()
                        }
                )
        } else {
            let isOpen = Binding(
                get: { openInspectorLabel == label },
                set: { value in openInspectorLabel = value ? label : nil }
            )
            Button {
                openInspectorLabel = label
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
                inspectorContent(label: label, events: events)
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
    private func faceButton(label: String, index: Int, tint: Color) -> some View {
        inspectable(label: label, events: [.button(index)]) {
            FaceButtonGlyph(label: label,
                            pressed: (state.buttons[index] ?? 0) > 0.5,
                            tint: tint)
        }
    }

    /// One menu pill (Share / Home / Menu) wrapped in inspectable.
    private func menuPill(label: String, index: Int) -> some View {
        let pressed = (state.buttons[index] ?? 0) > 0.5
        return inspectable(label: label, events: [.button(index)]) {
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
    fileprivate func inspectorContent(label: String, events: [InputEvent]) -> some View {
        let matchingBindings = matches(for: events)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.headline)
                Spacer()
                if !matchingBindings.isEmpty {
                    Text("\(matchingBindings.count) bound")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Motion widget gets an extra "Reset gyroscope" action so
            // the user can re-zero on a flat surface without leaving
            // the visualizer. The action samples the controller's
            // current motion reading and saves it as the new drift
            // baseline (same call site as the PresetEditor toolbar
            // button).
            if label == "Motion" {
                gyroResetActionRow
                Divider()
            }
            if matchingBindings.isEmpty {
                Text("No bindings in this preset target this input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let first = events.first {
                    Button {
                        openInspectorLabel = nil
                        onJump?(EditorJumpTarget(
                            joystickIndex: slot,
                            inputSerialized: first.serialized
                        ))
                    } label: {
                        Label("Open editor anyway", systemImage: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .help("Open the preset editor for this preset")
                }
            } else {
                ForEach(matchingBindings) { match in
                    Button {
                        openInspectorLabel = nil
                        onJump?(EditorJumpTarget(
                            joystickIndex: match.joystickIndex,
                            inputSerialized: match.binding.input.serialized
                        ))
                    } label: {
                        HStack(spacing: 8) {
                            Text("#\(match.displayNumber)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.secondary.opacity(0.18))
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                // A zone's generic type name ("Touchpad
                                // Region") tells you nothing when several are
                                // bound. Show the zone's own name next to the
                                // color it is drawn in on the map, so the one
                                // you just touched is the one you can see.
                                if let info = regionInfo(for: match.binding.input) {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(regionPaletteColor(at: info.colorIndex))
                                            .frame(width: 9, height: 9)
                                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                                        Text(info.name)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.primary)
                                    }
                                } else {
                                    Text(match.binding.input.displayName)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                                ForEach(match.binding.outputs) { out in
                                    Text(out.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if preset.joysticks.count > 1 {
                                    Text("Input Device \(match.joystickIndex)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.08))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to row #\(match.displayNumber) in the editor")
                }
            }
        }
        .padding(12)
        .frame(width: 280)
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

    /// Sample the current motion reading off every connected
    /// motion-capable controller and save it as the new drift
    /// baseline. Same algorithm as PresetEditorView.quickZeroGyro;
    /// reproduced here so the visualizer popover doesn't need to
    /// reach into the editor view's private state.
    private func resetGyroFromVisualizer() {
        var count = 0
        for controller in controllerService.connectedControllers {
            guard let motion = controller.motion else { continue }
            let key = MotionCalibrationService.identityKey(for: controller)
            MotionCalibrationService.shared.quickZero(
                forKey: key,
                gyroX: Float(motion.rotationRate.x),
                gyroY: Float(motion.rotationRate.y),
                gyroZ: Float(motion.rotationRate.z),
                accelX: Float(motion.userAcceleration.x),
                accelY: Float(motion.userAcceleration.y),
                accelZ: Float(motion.userAcceleration.z)
            )
            count += 1
        }
        // Reset the parent's integrated angles too so the on-screen
        // model immediately snaps back to center instead of slowly
        // drifting away from whatever orientation it was showing.
        integratedRoll = 0
        integratedPitch = 0
        integratedYaw = 0
        withAnimation(.easeInOut(duration: 0.18)) {
            gyroResetFeedback = count == 0
                ? "No motion-capable controller connected"
                : "Zeroed on \(count) controller\(count == 1 ? "" : "s")"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.18)) {
                gyroResetFeedback = nil
            }
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
                .foregroundStyle(.tertiary)
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
                .foregroundStyle(.tertiary)
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
            sampleAndPrune(now: now)
            refreshRegionState()
            for kind in [TouchpadGestureKind.oneFingerTap, .doubleTap, .twoFingerTap]
            where TouchpadService.shared.peekGesture(kind) {
                if lastTap != kind || now.timeIntervalSince(lastTapAt) > 0.3 {
                    lastTap = kind; lastTapAt = now
                }
            }
        }
        // Retain the TouchpadHelper subprocess while the widget is on
        // screen so finger positions flow into the visualizer regardless
        // of whether a touchpad-using preset is active. MappingEngine
        // separately retains it when needed; the ref-count keeps things
        // tidy when both want it running.
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
                                paused: trailF0.isEmpty && trailF1.isEmpty)) { context in
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
        let hasAttitude = abs(rawRoll) + abs(rawPitch) + abs(rawYaw) > 0.0001

        let roll  = hasAttitude ? rawRoll  : integratedRoll
        let pitch = hasAttitude ? rawPitch : integratedPitch
        let yaw   = hasAttitude ? rawYaw   : integratedYaw

        return GyroVisualizationView(
            gyroX: state.motion[.gyroX] ?? 0,
            gyroY: state.motion[.gyroY] ?? 0,
            gyroZ: state.motion[.gyroZ] ?? 0,
            rollAngle: roll,
            pitchAngle: pitch,
            yawAngle: yaw,
            mode: .compact
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
///     strength, bound notes carry a dot, octaves are labelled
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
            refresh(force: false)
        }
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
                     ? "No MIDI device connected - plug one in and this goes live"
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

            // Octave labels under every C.
            HStack(spacing: 0) {
                let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
                ForEach(whites, id: \.self) { note in
                    Text(note % 12 == 0 ? "C\(note / 12 - 2)" : "")
                        .font(.system(size: 7, weight: .medium).monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func noteAt(location: CGPoint) -> Int {
        let whites = (Self.lowNote...Self.highNote).filter { !Self.isBlackKey($0) }
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
            Text("Twist a knob or move a slider - every control appears here live.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                        .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.tertiary)
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
                        onJump?(EditorJumpTarget(
                            joystickIndex: match.joystickIndex,
                            inputSerialized: match.binding.input.serialized
                        ))
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
            .help(control.editMode ? "Finish customizing" : "Drag widgets to rearrange the layout")
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

            // Zoom: minus, slider, plus. Starts at the default size every
            // time the panel appears; zooming is for a closer look.
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

    @ObservedObject private var cursorService = CursorRegionService.shared

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

    var body: some View {
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
                        .foregroundStyle(.tertiary)
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
                        let colour = regionPaletteColor(at: region.colorIndex).opacity(here ? 1 : 0.35)
                        let rect = CGRect(x: region.minX * w, y: region.minY * h,
                                          width: (region.maxX - region.minX) * w,
                                          height: (region.maxY - region.minY) * h)
                        let swatch = RoundedRectangle(cornerRadius: 4)
                            .fill(colour.opacity(lit ? 0.55 : 0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(colour.opacity(lit ? 1 : 0.5), lineWidth: lit ? 2 : 1)
                            )
                            .overlay(
                                // A small corner region has no room for its
                                // name; the colour and the tooltip carry it.
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
                            if let onPick {
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
                // Centerd in whatever space is left over once it is fitted.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .frame(height: large ? 300 : (drawnAspect > 1.2 ? 170 : 200))
            .frame(maxWidth: large ? 520 : (drawnAspect > 1.2 ? 320 : 220))
            .onAppear { if liveCursor { cursorService.beginTracking() } }
            .onDisappear { if liveCursor { cursorService.endTracking() } }
            .accessibilityElement(children: .ignore)
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
        .onAppear { ChassisTapService.shared.retain("visualizer") }
        .onDisappear { ChassisTapService.shared.release("visualizer") }
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
