import SwiftUI

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
struct VirtualControllerView<Trailing: View>: View {
    @EnvironmentObject var controllerService: GameControllerService
    let preset: Preset
    /// Asks the host to open the preset editor and scroll/pulse the row that
    /// matches this input. Fired when the user clicks any matching binding
    /// in a widget popover, OR the "Jump to editor anyway" button when no
    /// binding currently targets the input.
    var onJump: ((EditorJumpTarget) -> Void)?

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

    /// User-adjustable size factor for the visualizer panel. Persisted in
    /// UserDefaults so the layout sticks across launches. Default 0.5 so
    /// the whole controller fits comfortably without zooming the user's
    /// window content out.
    @AppStorage("VirtualController.scale") private var visualizerScale: Double = 0.5

    /// User-adjustable pan offset for the controller layout inside the
    /// panel. Lets the user drag the controller around when zoomed in.
    /// Reset to .zero when the user lowers zoom to 0.5 or less.
    @State private var panOffset: CGSize = .zero
    @State private var dragInProgress: CGSize = .zero

    /// Popover state for the on-controller light-bar widget.
    @State private var showLightBarPopover: Bool = false

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
    /// flying to the centre of the screen).
    @State private var openInspectorLabel: String?

    // MARK: - Drag-to-rearrange

    /// True when the user has flipped the visualizer into "Customize layout"
    /// mode. While on, every widget sprouts a dashed yellow outline and can
    /// be dragged around. Clicks open the popover as usual when off.
    @State private var editMode: Bool = false
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
            header
                // Make sure the header sits ABOVE the controller panel for
                // hit testing - the TimelineView below re-renders 30 Hz and
                // can cover the button's tap region otherwise.
                .zIndex(2)
                .contentShape(Rectangle())

            // Visualizer panel - fills its parent area. The panel size is
            // static; only the controller widgets inside scale with the
            // zoom slider so the user gets closer/further-away framing
            // without resizing the window itself.
            ZStack {
                // Neutral panel background + always-on light grid so the
                // workspace always reads as a "workbench" surface. The
                // grid is more visible in customize mode (handled inside
                // gridOverlay).
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(
                        colors: [Color.secondary.opacity(0.08), Color.secondary.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
                    .overlay(gridOverlay)
                    .allowsHitTesting(false)

                // Self-refresh at 30 Hz - controllerService doesn't
                // publish `currentStates` (would re-render every observer
                // 30x/sec); TimelineView drives our redraw cadence.
                TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { _ in
                    controllerLayout
                        .scaleEffect(visualizerScale)
                        .offset(x: panOffset.width + dragInProgress.width,
                                y: panOffset.height + dragInProgress.height)
                        .padding(18)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 540)
            // Drag the controller content around inside the panel. The
            // panel itself doesn't move - only the layered widgets do.
            // Useful when zoomed in past the panel bounds.
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
            // Clip scaled-up widgets to the panel so zooming in past 1.0
            // doesn't bleed outside the workbench.
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if editMode {
                Text("Drag any widget to a new position. The layout saves automatically for this controller model.")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .padding(.top, 2)
            }
        }
        .onAppear { loadOffsets() }
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
            let dt: Float = 1.0 / 30.0
            integratedPitch += gx * dt
            integratedYaw   += gy * dt
            integratedRoll  += gz * dt
            integratedPitch = max(-(.pi / 2), min(.pi / 2, integratedPitch))
            integratedYaw   = max(-(.pi / 2), min(.pi / 2, integratedYaw))
            integratedRoll  = max(-(.pi / 2), min(.pi / 2, integratedRoll))
        }
    }

    // MARK: - Header

    private var header: some View {
        // "Live Visualizer" title intentionally omitted - the outer
        // DisclosureGroup in PresetDetailView already labels this section,
        // so repeating it here was redundant.
        HStack(spacing: 10) {
            // Prominent customize toggle. Bordered-prominent + regular
            // control size gives a generous hit region; the smaller
            // .bordered + .small variant was being clipped to a tiny tap
            // target that was hard to hit reliably.
            Button {
                editMode.toggle()
                openInspectorLabel = nil
            } label: {
                Label(editMode ? "Done Editing" : "Customize Layout",
                      systemImage: editMode ? "checkmark.circle.fill" : "pencil.and.outline")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(editMode ? .green : .blue)
            .help(editMode ? "Finish customizing" : "Drag widgets to rearrange the layout")
            .spotlightAnchor(SpotlightID.customizeButton)

            if editMode {
                Button {
                    dragOffsets.removeAll()
                    persistOffsets()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Reset all widgets to their default position")
            }

            Spacer()

            // Reset pan + zoom to defaults if the user wants to recentre.
            if panOffset != .zero || visualizerScale != 0.5 {
                Button {
                    panOffset = .zero
                    dragInProgress = .zero
                    visualizerScale = 0.5
                } label: {
                    Image(systemName: "scope")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Recenter and reset zoom")
            }

            // Size slider so the user can shrink or enlarge the controller
            // widgets inside the visualizer (the panel itself stays the
            // same size). Persists per user via @AppStorage. Range 0.3 -
            // 1.5 to match the new wider default zoom-out floor.
            HStack(spacing: 4) {
                Button {
                    visualizerScale = max(0.3, visualizerScale - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Shrink visualizer")

                Slider(value: $visualizerScale, in: 0.3...1.5)
                    .frame(width: 80)
                    .help("Resize the live visualizer content")

                Button {
                    visualizerScale = min(1.5, visualizerScale + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Enlarge visualizer")
            }

            slotPicker
            statusDot
        }
    }

    /// Always-on light gray grid overlay. The lines are very faint by
    /// default so they read as background texture; in customize mode
    /// they brighten to provide a clear "workbench" feel for the drag
    /// interaction.
    private var gridOverlay: some View {
        Canvas { context, size in
            let minorOpacity: Double = editMode ? 0.18 : 0.06
            let majorOpacity: Double = editMode ? 0.32 : 0.10
            let minor = Color.secondary.opacity(minorOpacity)
            let major = Color.secondary.opacity(majorOpacity)
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

    @ViewBuilder
    private var slotPicker: some View {
        if fixedSlot != nil {
            Text(controllerService.controllerName(at: slot))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            let slots = Array(controllerService.controllerDetails.keys).sorted()
            if slots.count > 1 {
                Picker("Slot", selection: $slotState) {
                    ForEach(slots, id: \.self) { s in
                        Text(controllerService.controllerName(at: s)).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
            } else if let only = slots.first {
                Text(controllerService.controllerName(at: only))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onAppear { slotState = only }
            } else {
                Text("No controller connected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusDot: some View {
        let connected = controllerService.controllerDetails[slot] != nil
        return Circle()
            .fill(connected ? Color.green : Color.red.opacity(0.7))
            .frame(width: 8, height: 8)
    }

    // MARK: - Layout

    private var state: ControllerState {
        controllerService.currentStates[slot] ?? ControllerState()
    }

    private var info: ControllerInfo? {
        controllerService.controllerDetails[slot]
    }

    @ViewBuilder
    private var controllerLayout: some View {
        VStack(spacing: 14) {
            // Light-bar strip - rendered only for controllers that actually
            // have one (DualSense, DualShock 4). Sits at the top like the
            // real DualSense light bar that wraps over the touchpad. Click
            // to open the per-preset color settings as a popover anchored
            // right where the strip is.
            if info?.hasLight == true {
                lightBarStripWidget
            }

            // Top row: bumpers + triggers
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 8) {
                    inspectable(label: "LT", events: [.axis(4, direction: .positive)]) {
                        TriggerWidget(label: "LT", value: state.axes[4] ?? 0,
                                      threshold: thresholdForAxis(4, dir: .positive),
                                      tint: .blue)
                    }
                    inspectable(label: "LB", events: [.button(4)]) {
                        ShoulderWidget(label: "LB", pressed: (state.buttons[4] ?? 0) > 0.5)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        menuPill(label: "Share", index: 8)
                        menuPill(label: "Home", index: 10)
                        menuPill(label: "Menu", index: 9)
                    }
                    motionWidgetIfAvailable
                }
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    inspectable(label: "RT", events: [.axis(5, direction: .positive)]) {
                        TriggerWidget(label: "RT", value: state.axes[5] ?? 0,
                                      threshold: thresholdForAxis(5, dir: .positive),
                                      tint: .red)
                    }
                    inspectable(label: "RB", events: [.button(5)]) {
                        ShoulderWidget(label: "RB", pressed: (state.buttons[5] ?? 0) > 0.5)
                    }
                }
            }

            // Middle row: D-pad + face buttons (each face button is its
            // own popover anchor so the inspector pops next to the press).
            HStack(alignment: .center) {
                inspectable(label: "D-pad", events: [
                    .hat(0, direction: .up), .hat(0, direction: .right),
                    .hat(0, direction: .down), .hat(0, direction: .left)
                ]) {
                    DPadWidget(hat: state.hats[0] ?? (0, 0))
                }
                Spacer(minLength: 0)
                ZStack {
                    faceButton(label: "Y", index: 3, tint: .yellow).offset(y: -22)
                    faceButton(label: "A", index: 0, tint: .green).offset(y: 22)
                    faceButton(label: "X", index: 2, tint: .blue).offset(x: -22)
                    faceButton(label: "B", index: 1, tint: .red).offset(x: 22)
                }
                .frame(width: 88, height: 88)
            }

            // Sticks row
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

            // Touchpad (only when the controller actually has one).
            // Press state comes from button 13 - when down, the widget
            // glows green to signal a click vs a surface swipe.
            if info?.hasTouchpad == true {
                inspectable(label: "Touchpad", events: [
                    .touchpad(finger: 0, axis: .x, direction: .positive),
                    .touchpad(finger: 0, axis: .y, direction: .positive),
                    .button(13)
                ]) {
                    TouchpadWidget(pressed: (state.buttons[13] ?? 0) > 0.5)
                }
            }

            // Extra / unknown buttons row - shown when the controller
            // exposes any non-standard physical buttons. Pulls from the
            // service's authoritative snapshot which now includes
            // KVC-discovered DualSense / DualSense Edge buttons (mute,
            // paddles, FN) the typed Apple API doesn't expose in this
            // SDK.
            let extras = controllerService.extraButtonsSnapshot(for: slot)
                .filter { ![13].contains($0.index) }  // Touchpad has its own widget
            if !extras.isEmpty {
                extraButtonsWidget(extras: extras)
            }
        }
    }

    @ViewBuilder
    private func extraButtonsWidget(extras: [GameControllerService.ExtraButton]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra buttons")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowChipRow(chips: extras.map { extra in
                let color: Color = extra.pressed ? .green : .secondary
                return (extra.label, color)
            })
        }
        .padding(.top, 4)
    }

    /// Clickable light-bar strip that mimics the real DualSense's top
    /// LED bar. Filled with the preset's chosen color when set, or a
    /// faint shimmering "click to set" placeholder otherwise. Tap to open
    /// the per-preset Light Bar editor in a popover anchored right here.
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
                        // Subtle barber-pole pattern to telegraph "click me".
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
        .spotlightAnchor(SpotlightID.lightBarStrip)
        .popover(isPresented: $showLightBarPopover, arrowEdge: .top) {
            trailing()
                .padding(4)
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

    private func setInspector(label: String) {
        openInspectorLabel = label
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                                Text(match.binding.input.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                ForEach(match.binding.outputs) { out in
                                    Text(out.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if preset.joysticks.count > 1 {
                                    Text("Joystick #\(match.joystickIndex)")
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

    var body: some View {
        ZStack {
            Circle()
                .fill(pressed ? tint.opacity(0.4) : Color.secondary.opacity(0.18))
            Circle()
                .stroke(pressed ? tint : Color.secondary.opacity(0.35), lineWidth: 1.5)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(pressed ? tint : Color.secondary)
        }
        .frame(width: 28, height: 28)
    }
}

private struct TouchpadWidget: View {
    /// Touchpad button (index 13) state. When the user physically pushes
    /// the touchpad down (not just touches it), this flips to true and the
    /// widget glows green to signal a click vs a swipe.
    let pressed: Bool

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
    private let trailDuration: TimeInterval = 0.55
    /// Width / height of the rendered touchpad rect.
    private let pad = CGSize(width: 220, height: 70)
    /// Sampled-coordinate range (matches the helper subprocess output).
    private let coordScale = CGSize(width: 1920, height: 1080)

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

            // Trails first, dots on top.
            trailRender(points: trailF0, hue: .mint)
            trailRender(points: trailF1, hue: .cyan)
            dotRender(point: trailF0.last, hue: .mint, base: 12)
            dotRender(point: trailF1.last, hue: .cyan, base: 10)

            Text("Touchpad")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .position(x: 32, y: 8)
        }
        .frame(width: pad.width, height: pad.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // 60 Hz sampling so quick flicks leave a smooth, dense trail.
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { now in
            sampleAndPrune(now: now)
        }
        // Retain the TouchpadHelper subprocess while the widget is on
        // screen so finger positions flow into the visualizer regardless
        // of whether a touchpad-using preset is active. MappingEngine
        // separately retains it when needed; the ref-count keeps things
        // tidy when both want it running.
        .onAppear { TouchpadService.shared.retain() }
        .onDisappear { TouchpadService.shared.release() }
    }

    /// Draw a trail of fading points behind the most recent finger
    /// position. Older samples shrink AND fade so the freshest point
    /// always appears largest.
    @ViewBuilder
    private func trailRender(points: [TrailPoint], hue: Color) -> some View {
        let now = Date()
        ForEach(points) { p in
            let age = now.timeIntervalSince(p.time)
            let factor = max(0, 1 - age / trailDuration)
            Circle()
                .fill(hue.opacity(0.55 * factor))
                .frame(width: 4 + 8 * factor, height: 4 + 8 * factor)
                .blur(radius: 1.5)
                .position(x: p.x / coordScale.width * pad.width,
                          y: p.y / coordScale.height * pad.height)
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
    private func sampleAndPrune(now: Date) {
        if let p = TouchpadService.shared.currentPosition(finger: 0) {
            trailF0.append(TrailPoint(x: CGFloat(p.x), y: CGFloat(p.y), time: now))
        }
        if let p = TouchpadService.shared.currentPosition(finger: 1) {
            trailF1.append(TrailPoint(x: CGFloat(p.x), y: CGFloat(p.y), time: now))
        }
        let cutoff = now.addingTimeInterval(-trailDuration)
        trailF0.removeAll { $0.time < cutoff }
        trailF1.removeAll { $0.time < cutoff }
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
    }
}
