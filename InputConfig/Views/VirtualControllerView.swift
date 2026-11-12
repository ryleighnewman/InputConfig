import SwiftUI
import Combine

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
        guard mag > 0.15 else { return String(localized: "centered") }
        let step = Int((min(1, mag) * 4).rounded()) * 25
        var dir: [String] = []
        if y < -0.35 { dir.append(String(localized: "up")) } else if y > 0.35 { dir.append(String(localized: "down")) }
        if x < -0.35 { dir.append(String(localized: "left")) } else if x > 0.35 { dir.append(String(localized: "right")) }
        return String(localized: "\(dir.isEmpty ? String(localized: "off center") : dir.joined(separator: " ")) \(step) percent")
    }
    /// A single signed axis in quarter steps: "plus 50 percent", "centered".
    static func axis(_ v: Float) -> String {
        let step = Int((min(1, abs(v)) * 4).rounded()) * 25
        guard step > 0 else { return String(localized: "centered") }
        return v < 0 ? String(localized: "minus \(step) percent") : String(localized: "plus \(step) percent")
    }
    /// A trigger in quarter steps: "released", "50 percent", "fully pressed".
    static func trigger(_ v: Float) -> String {
        let step = Int((min(1, max(0, v)) * 4).rounded()) * 25
        switch step {
        case 0: return String(localized: "released")
        case 100: return String(localized: "fully pressed")
        default: return String(localized: "\(step) percent")
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
/// Observable, not ObservableObject: each view re-runs for what it reads.
/// A switch's scale and editMode writes of the same values re-ran the
/// panel and the header, and showingModel, which the panel only writes,
/// re-ran the panel.
@MainActor @Observable
final class VisualizerControlState {
    var editMode = false
    /// The size the map is drawn at, set by the zoom control on the host's
    /// title row (minus, slider, plus).
    var scale: Double = 1.0
    /// Bumped by the host's Reset button; the panel clears its offsets.
    var resetToken = 0
    /// The panel is drawing a controller model, whose controls stay where
    /// the real ones are, so there is little to rearrange.
    var showingModel = false
}

/// The region editors a map's popover can open: Touchpad Setup for touchpad
/// zones, the drawing sheet for screen regions, the stick zone editor.
enum VisualizerRegionEditor: Equatable {
    case touchpadSetup, screenRegions
    /// On one stick (0, 1) or one axis's bands (100 plus the axis); nil
    /// lets the sheet's title pick.
    case stickZones(key: Int?)

    var buttonTitle: String {
        switch self {
        case .touchpadSetup: return String(localized: "Edit touchpad regions")
        case .screenRegions: return String(localized: "Edit screen regions")
        case .stickZones(let key):
            return (key ?? 0) >= StickRegionService.bandKeyBase
                ? String(localized: "Edit trigger regions")
                : String(localized: "Edit stick regions")
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
        case .normal: return String(localized: "Normal")
        case .blueprint: return String(localized: "Blueprint")
        case .black: return String(localized: "Black")
        case .slate: return String(localized: "Slate")
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
    /// The app's reading direction. The drawings are pinned left to right;
    /// the popovers they open read in the app's own direction again.
    @Environment(\.layoutDirection) var appDirection
    // No mapping engine here: nothing read it, and as an EnvironmentObject
    // it re-ran this whole panel on every engine publish.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appHighContrast) private var appHighContrast
    /// A press shown by more than hue (see ControllerCanvas).
    var pressedOutline: Bool { differentiateWithoutColor || colorSchemeContrast == .increased || appHighContrast }
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
    /// Redraws the light bar chip when Settings changes the switch.
    @AppStorage(GameControllerService.leaveLightBarKey) var lightBarLeftToSystem = false
    /// This instance's name on the keyboard / mouse monitor. Unique per
    /// instance: when a preset changes, the old visualizer's disappear
    /// can run after the new one's appear, and a shared name let that
    /// late release wipe the new hold.
    @State private var externalHold = "visualizer-" + UUID().uuidString
    /// The Face button names setting, observed so the drawn letters change
    /// the moment it does.
    @AppStorage(FaceLetters.defaultsKey) var faceLettersRaw = FaceLetters.automatic.rawValue
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
    /// Just the drawing, for a printed page: no menus, grid or backdrop.
    var printing: Bool = false

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
    /// A trigger's feel set from its inspector: left or right, 0 to 3.
    var onChangeTriggerFeel: ((_ left: Bool, _ level: Int) -> Void)? = nil

    /// Edit mode and zoom live with the host, which draws their controls on
    /// the Live Visualizer title row; the panel reads and writes them here.
    @Bindable var control: VisualizerControlState
    private var visualizerScale: Double {
        get { control.scale }
        nonmutating set { control.scale = newValue }
    }
    var editMode: Bool {
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
            let pan = CGSize(width: saved["x"] ?? 0, height: saved["y"] ?? 0)
            if panOffset != pan { panOffset = pan }
            // Only a change: @Published sends on every write, and an equal
            // one re-ran the panel and the title row once more per switch.
            let scale = min(1.5, max(0.3, saved["scale"] ?? 1))
            if control.scale != scale { control.scale = scale }
        } else {
            if panOffset != .zero { panOffset = .zero }
            if control.scale != 1 { control.scale = 1 }
        }
        DispatchQueue.main.async { restoringView = false }
    }

    /// Moves the zoomed map a step, as a drag would.
    private func pan(dx: CGFloat, dy: CGFloat) {
        panOffset = clampedPan(CGSize(width: panOffset.width + dx, height: panOffset.height + dy))
        saveView()
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
    @State var showLightBarPopover: Bool = false
    /// The controller's stored profiles, from the chip above the drawing.
    @State var showProfilesPopover: Bool = false
    /// The Access controller profile open in the editor beside the
    /// drawing, the drawing control its selected row is about, and the
    /// save in flight.
    @State var accessProfileEditing: AccessControllerPortService.Profile? = nil
    @State var accessEditorSelection: String? = nil
    @State var accessEditorSaving = false
    @State var accessEditorError: String? = nil
    /// The profile as read from the controller, so Save knows when
    /// nothing changed, and the device it was read from: the editor
    /// closes when that pad goes away or the slot reads another.
    @State var accessEditorOriginal: AccessControllerPortService.Profile? = nil
    @State var accessEditorDevice: String? = nil

    /// Transient feedback after the user clicks "Reset gyroscope" in
    /// the Motion popover. Shows for ~1.5s then clears.
    @State var gyroResetFeedback: String?

    /// Integrated gyro orientation (radians). Owned at this level so the
    /// integrator timer is created exactly ONCE (placing it inside
    /// MotionWidget caused it to be recreated on every 30 Hz render of
    /// the parent TimelineView, which destabilized the subscription and
    /// made the model freeze after the first tick).
    @State var integratedRoll: Float = 0
    @State var integratedPitch: Float = 0
    @State var integratedYaw: Float = 0

    @State private var slotState: Int = 0
    var slot: Int { fixedSlot ?? slotState }
    /// Per-widget open-popover flags. Keyed by widget label so each widget
    /// owns its own popover anchored at its own bounds (no more popovers
    /// flying to the center of the screen).
    @State var openInspectorLabel: String?

    // MARK: - Drag-to-rearrange

    /// True when the user has flipped the visualizer into "Customize layout"
    /// mode. While on, every widget sprouts a dashed yellow outline and can
    /// be dragged around. Clicks open the popover as usual when off.
    /// Per-widget offsets from each widget's structural position. Persisted
    /// to UserDefaults per controller model so each controller remembers its
    /// custom layout independently.
    @State var dragOffsets: [String: CGSize] = [:]
    /// Live offset while the user is mid-drag, so the widget tracks the
    /// finger before we commit the new persisted offset on drag-end.
    @State var liveDrag: (label: String, translation: CGSize)?

    /// UserDefaults key for this controller model's saved offsets.
    var layoutStorageKey: String {
        let category = controllerService.controllerDetails[deviceSlot]?.productCategory ?? "Default"
        return "VirtualController.layout.\(category)"
    }

    @ViewBuilder
    var body: some View {
        if printing { controllerLayout(resolvedLayout) } else { panel }
    }

    @ViewBuilder
    private var panel: some View {
        #if DEBUG
        let _ = BodyRuns.note("VirtualControllerView")
        let _ = BodyRuns.printChangesIfAsked() ? Self._printChanges() : ()
        #endif
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
            // Redrawn when the drawn state changed (the signature timer
            // below bumps the clock), not on a 30 Hz schedule: a button
            // press used to cost about thirty full re-renders for its two
            // changes, with the 0.7 s idle tail. The clock lives in a
            // child view, so only the panel re-renders, not this body.
            VisualizerLiveHost(clock: renderClock) {
                visualizerPanelContent
                    // The screen map and the keyboard and mouse diagrams
                    // redraw on their own publishers, not this clock: they
                    // pause by the same rule, or kept redrawing at 60 Hz
                    // with another app in front.
                    .environment(\.visualizerSuspended, visualizerSuspended || !panelWatched)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appIsActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appIsActive = false }
            // The window covered, hidden or minimized is nobody looking
            // either, as MIDIInstrumentView reads it.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
                mainWindowVisible = Self.mainWindowIsVisible
            }
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
            // The profile editor is about one controller: when it is
            // unplugged or the slot reads another, the edits are about
            // nothing, so the editor closes.
            .onChange(of: accessEditorDeviceKey) { _, key in
                if accessProfileEditing != nil, key != accessEditorDevice { closeAccessEditor() }
            }
            // Drawn as something else now (a template pick, a different
            // pad resolved): the editor has no drawing to refer to.
            .onChange(of: resolvedLayout?.layout.id) { _, id in
                if accessProfileEditing != nil, id != .psAccess { closeAccessEditor() }
            }
            // The shared 30 Hz tick (VisualizerTicker), running only while a
            // watched panel has a pad to show. A Timer.publish here fired
            // with no pad and nobody looking too, and was made anew on every
            // evaluation of this body.
            .onReceive(VisualizerTicker.shared.ticks) { _ in
                // Nobody is looking while another app is in front, and the
                // clock above is paused then too.
                guard info != nil, panelWatched, !visualizerSuspended else { return }
                // A finger on a PlayStation touchpad changes no state the
                // pad reports, so its position counts too: the clock then
                // runs while a finger moves and idles when none does.
                var sig = renderSignature(state)
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
                    renderClock.generation &+= 1
                    if visualizerIdle { visualizerIdle = false }
                } else if !visualizerIdle,
                          CACurrentMediaTime() - lastSignatureChangeAt > 0.7 {
                    visualizerIdle = true
                    // One more frame at rest: the signature rounds values to
                    // a grid, so the last small move (a trigger settling, a
                    // wheel's last degrees) changed nothing it tracks and
                    // was left undrawn.
                    renderClock.generation &+= 1
                }
            }
            // Grab the map anywhere in the box and move it. The whole box
            // takes the drag: without the shape, only the drawn controls
            // could be grabbed and the empty space around them let the drag
            // fall through. A control's own click or drag (Edit Layout)
            // still comes first.
            .contentShape(RoundedRectangle(cornerRadius: 16))
            // In Edit Layout the drag belongs to the widgets alone: the
            // box's pan took a widget drag that started a hair outside it.
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
                    },
                including: control.editMode ? .subviews : .all
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
                    // Panning without a drag, for VoiceOver, Switch Control
                    // and keyboard users with the map zoomed in.
                    .accessibilityAction(named: "Pan left") { pan(dx: 40, dy: 0) }
                    .accessibilityAction(named: "Pan right") { pan(dx: -40, dy: 0) }
                    .accessibilityAction(named: "Pan up") { pan(dx: 0, dy: 40) }
                    .accessibilityAction(named: "Pan down") { pan(dx: 0, dy: -40) }
                    .padding(10)
                }
            }
            .contextMenu {
                if control.scale != 1 || panOffset != .zero {
                    Button("Pan Left") { pan(dx: 40, dy: 0) }
                    Button("Pan Right") { pan(dx: -40, dy: 0) }
                    Button("Pan Up") { pan(dx: 0, dy: 40) }
                    Button("Pan Down") { pan(dx: 0, dy: -40) }
                }
            }

            if editMode {
                Text("Drag any widget to a new position, or Tab to it and press the arrow keys, or right-click it, to move it a step at a time. The layout saves automatically for this controller model.")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .padding(.top, 2)
            }
        }
        .onAppear {
            loadOffsets()
            loadView()
        }
        .onDisappear {
            if panCursorPushed { NSCursor.pop(); panCursorPushed = false }
            if liveHeld {
                liveHeld = false
                controllerService.releaseLiveInput(externalHold)
            }
            VisualizerTicker.shared.release(externalHold)
            ExternalInputDeviceService.shared.release(externalHold)
        }
        // Live input (the 30 Hz snapshot, the IMU stream, the DualSense
        // report stream, raw decoding, the wheels) is held only while
        // someone can see this panel with a pad in its slot. Held for the
        // panel's whole life, all of it ran behind a game, hidden or
        // minimized, for a picture nobody saw: about 280 main thread wakeups
        // a second per DualSense with a preset running, 530 with none. Let
        // go 1.5 s after the panel stops being watched, so a quick app
        // switch does not turn the IMU off and on. Kept under the editor:
        // the editor holds its own, and letting go there stopped and
        // restarted every stream when the editor closed.
        .task(id: liveWanted) {
            if liveWanted {
                guard !Task.isCancelled, !liveHeld else { return }
                liveHeld = true
                controllerService.retainLiveInput(externalHold)
            } else {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, liveHeld else { return }
                liveHeld = false
                controllerService.releaseLiveInput(externalHold)
            }
        }
        // The tick the two handlers here redraw and integrate on, held by
        // the same rule, and not under the editor, where both return.
        .onChange(of: liveWanted && !visualizerSuspended, initial: true) { _, wanted in
            if wanted {
                VisualizerTicker.shared.hold(externalHold)
            } else {
                VisualizerTicker.shared.release(externalHold)
            }
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
        .onChange(of: preset.id) { _, _ in
            loadView()
            // The page lives across preset switches: nothing open on the
            // old preset stays open on this one. Each only when set: the
            // usual switch has nothing open, and writes nothing.
            if openInspectorLabel != nil { openInspectorLabel = nil }
            if showLightBarPopover { showLightBarPopover = false }
            if showProfilesPopover { showProfilesPopover = false }
            if liveDrag != nil { liveDrag = nil }
            if dragInProgress != .zero { dragInProgress = .zero }
            if gyroResetFeedback != nil { gyroResetFeedback = nil }
            if accessProfileEditing != nil { accessProfileEditing = nil }
            if accessEditorSelection != nil { accessEditorSelection = nil }
            if accessEditorSaving { accessEditorSaving = false }
            if accessEditorError != nil { accessEditorError = nil }
            if accessEditorOriginal != nil { accessEditorOriginal = nil }
            if accessEditorDevice != nil { accessEditorDevice = nil }
            if fixedSlot == nil, slotState != 0 { slotState = 0 }
        }
        // The pad behind the panel changed (a Connected pick, pads shifting
        // slots): its own saved layout, not the last one's written over it.
        .onChange(of: layoutStorageKey) { _, _ in loadOffsets() }
        .onChange(of: slot) { _, _ in
            loadOffsets()
            loadView()
            // Different controller, different orientation context. Reset
            // so the new controller starts from neutral.
            integratedRoll = 0
            integratedPitch = 0
            integratedYaw = 0
        }
        // Single stable 30 Hz integrator, on the shared tick. Reads the
        // latest gyro rates from controllerService.currentStates each tick
        // and accumulates into the @State angle vars - which MotionWidget
        // below reads.
        .onReceive(VisualizerTicker.shared.ticks) { _ in
            guard panelWatched, !visualizerSuspended else { return }
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
            // 0.05: at 0.02 a resting DualSense still crept past the band
            // every few ticks and kept the view dirty.
            let deadband: Float = 0.05
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
        .onReceive(NotificationCenter.default.publisher(for: .inputConfigTourInspect)) { note in
            openInspectorLabel = note.object as? String
        }
        .debugEditLayout($control.editMode)
        .debugVizZoom($control.scale)
        #if DEBUG
        .onReceive(DebugMarketing.shared.$cursorRegionSize) { debugCursorRegionSize = $0 }
        // `post inputconfig.debug.inspect canvas-r2` opens that control's inspector.
        .onReceive(DebugHookRelay.shared.publisher("inputconfig.debug.inspect")) { note in
            openInspectorLabel = note.object as? String
        }
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
            // From one step in to one step short of the far edge: a line on
            // the edge itself read as the box's border on the straight sides
            // and vanished where the rounded corners clip it.
            var minorPath = Path()
            var x: CGFloat = minorStep
            while x < size.width {
                minorPath.move(to: CGPoint(x: x, y: 0))
                minorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += minorStep
            }
            var y: CGFloat = minorStep
            while y < size.height {
                minorPath.move(to: CGPoint(x: 0, y: y))
                minorPath.addLine(to: CGPoint(x: size.width, y: y))
                y += minorStep
            }
            context.stroke(minorPath, with: .color(minor), lineWidth: 0.5)

            // Major grid (slightly bolder).
            var majorPath = Path()
            x = majorStep
            while x < size.width {
                majorPath.move(to: CGPoint(x: x, y: 0))
                majorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += majorStep
            }
            y = majorStep
            while y < size.height {
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
    @State var appIsActive: Bool = NSApp.isActive
    @State private var mainWindowVisible: Bool = Self.mainWindowIsVisible
    /// Somebody can see the panel: the app in front and its window not
    /// covered, hidden or minimized. The clocks below stop otherwise.
    private var panelWatched: Bool { appIsActive && mainWindowVisible }
    /// Live input is wanted: the panel watched with a pad in its slot.
    private var liveWanted: Bool { panelWatched && info != nil }
    /// This panel holds live input now (see the task on liveWanted).
    @State private var liveHeld = false
    private static var mainWindowIsVisible: Bool {
        MenuBarController.mainWindow?.occlusionState.contains(.visible) ?? true
    }
    /// Last quantized state fingerprint + when it last moved. Plain change
    /// bookkeeping for the idle detector.
    @State private var lastRenderSignature: Int = 0
    /// Bumped when the drawn state changed; the live panel observes it.
    /// A plain box here, so this body does not.
    @State private var renderClock = VisualizerRenderClock()
    @State private var lastSignatureChangeAt: CFTimeInterval = 0

    var state: ControllerState {
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
    private func renderSignature(_ s: ControllerState) -> Int {
        // Non-finite reads 0: Int(NaN) traps, and one uncalibrated gyro
        // sample just after a pad connects was enough to crash.
        func q(_ v: Float) -> Int { v.isFinite ? Int((min(1e6, max(-1e6, v)) * 50).rounded()) : 0 }
        var acc = 0
        // A mouse or trackpad connected by hand moves the pointer itself:
        // its motion is no change worth a redraw. Counted, it kept the
        // panel redrawing at 30 Hz while the person moved the pointer to
        // click something, and a slower Mac lagged on every click.
        let pointing = controllerService.rawHIDGamepadSlots[deviceSlot]?.isPointingDevice == true
        for (k, v) in s.buttons {
            var h = Hasher(); h.combine(0); h.combine(k); h.combine(q(v))
            acc ^= h.finalize()
        }
        for (k, v) in s.axes where !pointing {
            var h = Hasher(); h.combine(1); h.combine(k); h.combine(q(v))
            // A bound axis crossing its row's deadzone inside one 0.02
            // bucket still lights the marker, so it counts as a change.
            if let past = axisPastDeadzone(k, value: v) { h.combine(past) }
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
            h.combine(v.isFinite ? Int((min(1e6, max(-1e6, v)) * 10).rounded()) : 0)
            acc ^= h.finalize()
        }
        return acc
    }

    /// Whether the axis reads past the deadzone of the first row in this
    /// group that reads it the way it is moving; nil when no row does.
    private func axisPastDeadzone(_ index: Int, value: Float) -> Bool? {
        guard slot < preset.joysticks.count else { return nil }
        let dir: AxisDirection = value < 0 ? .negative : .positive
        let row = preset.joysticks[slot].bindings.first {
            $0.input.type == .axis && $0.input.index == index
                && ($0.input.axisDirection == nil || $0.input.axisDirection == dir)
        }
        guard let row else { return nil }
        return abs(value) >= (row.deadzone ?? 0.25)
    }

    var info: ControllerInfo? {
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
        // A map picked by hand wins.
        if j.inputKind == .auto || j.inputKind == .touchpad,
           !j.bindings.isEmpty, j.bindings.allSatisfy({ [.cursorRegion, .screenPixel, .screenText, .voicePhrase].contains($0.input.type) }) { return .screen }
        if j.inputKind != .auto { return j.inputKind }
        guard !j.bindings.isEmpty else { return .controller }
        var counts: [SlotInputKind: Int] = [:]
        for b in j.bindings {
            switch b.input.type {
            case .extKey, .keySequence:
                counts[.keyboard, default: 0] += 1
            case .extMouse:
                counts[.mouse, default: 0] += 1
            case .touchpad, .touchpadRegion, .touchpadGesture:
                counts[.touchpad, default: 0] += 1
            case .cursorRegion, .screenPixel, .screenText, .voicePhrase:
                counts[.screen, default: 0] += 1
            case .midi:
                counts[.midi, default: 0] += 1
            default:
                counts[.controller, default: 0] += 1
            }
        }
        // Ties broken by a fixed order: a dictionary's order changes from
        // launch to launch, and the map flipped with it. max(by:) keeps the
        // first of equal elements, so the kind listed first wins.
        let order: [SlotInputKind] = [.controller, .keyboard, .mouse, .touchpad, .screen, .midi]
        return order.filter { counts[$0] != nil }.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .controller
    }

    /// The visualizer panel chrome + content, extracted so the live
    /// (TimelineView) and static (no controller) paths render the exact
    /// same thing.
    private var visualizerPanelContent: some View {
        // Resolved once per frame and handed down: the map, its zone maps
        // and the canvas each asked, and every ask read the pad again.
        let resolved = resolvedLayout
        // ONLY the controller map scales and pans. The gradient/grid box used to
        // live inside this scaleEffect, so the box itself grew with the zoom and,
        // past ~1x, its edges scaled clean out of the visible frame - leaving the
        // map with no stationary container and painting out over the sidebar and
        // window. The box is now a FIXED backdrop applied on the outer frame (see
        // body), so it stays put as a viewport and the zoomed map is clipped
        // inside it. Nothing here changes the view's layout footprint, which is
        // what lets that outer clip actually contain the scaled render.
        return controllerLayout(resolved)
            // Hold the map to a controller-sized column. Without this the
            // spacers between the widget groups stretch to the panel's full
            // width, which scattered the triggers to the far edges and left
            // a hole in the middle. The profile editor beside the drawing
            // gets a column of its own.
            .frame(maxWidth: accessProfileEditing != nil ? 520 + 346 : 520)
            .padding(18)
            .scaleEffect(visualizerScale, anchor: .center)
            .offset(x: panOffset.width + dragInProgress.width,
                    y: panOffset.height + dragInProgress.height)
            // Zoomed, the map is drawn as one picture at its final size, so
            // text and lines stay sharp: scaleEffect alone magnified what was
            // drawn at 100% and blurred it. The picture spans the whole box,
            // so the zoomed map is not cut short at its own column. Not the
            // screen regions map, whose display menu is an AppKit control a
            // drawing group cannot show, nor the keyboard (its shape and
            // layout menu) or MIDI (its knob row and Bound notes menu).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(SharpZoom(active: visualizerScale != 1 && ![.screen, .keyboard, .midi].contains(effectiveInputKind)))
    }

    /// The stationary gradient + grid + border backdrop the visualizer map sits
    /// inside. It is applied to the outer frame (not the scaled content), so it
    /// never zooms: it is the fixed viewport that bounds the map. The grid reads
    /// as stable workbench paper the controller scales and pans across.
    private var visualizerBoxBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(background.fill)
            .overlay(gridOverlay)
            // The outline over the grid, inside the edge, so it runs
            // unbroken round the corners.
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func controllerLayout(_ resolved: ResolvedLayout?) -> some View {
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
                // Voice phrases alone have no picture: the list is all of it.
                if !slotIsVoiceOnly { screenLayout }
            case .controller, .auto:
                if info == nil && !slotHasAnyBinding && (slot >= preset.joysticks.count || preset.joysticks[slot].controllerModel == nil) {
                    emptyVisualizerPlaceholder
                } else if slotIsMacTapsOnly {
                    // Tap the Mac: the input is the computer itself, so a
                    // controller drawing here would be about nothing. The
                    // tap map below is the whole picture.
                    EmptyView()
                } else if let resolved, resolved.layout.isComplete {
                    canvas(resolved)
                        .onAppear { control.showingModel = true }
                        .onDisappear { control.showingModel = false }
                } else {
                    // Hardware: never mirrored for right-to-left languages
                    // (inspectable puts the app's direction back in popovers).
                    controllerWidgets
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            // The regions this preset defines, whichever template is up:
            // screen areas and stick zones draw their own maps (touchpad
            // zones are drawn on the touchpad widget itself).
            regionMaps(resolved)
        }
    }

    /// Maps for the region kinds the preset defines. Each one lights the
    /// region the live point is inside, so the visualizer answers "which
    /// zone am I in" without running the preset.
    @ViewBuilder
    private func regionMaps(_ resolved: ResolvedLayout?) -> some View {
        // Screen regions are not here: the display is its own template
        // (`screenLayout`), so a controller's pad never has a screen map
        // hanging under it.
        if boundTapCounts.isEmpty == false {
            TapMapView(counts: boundTapCounts)
        }
        // The screen color, screen text and voice phrase rows have no
        // place on any drawing: a list of them, each with what its
        // service reads now.
        if showsScreenAndVoice {
            ScreenVoiceStatusView(preset: preset, live: panelWatched && !visualizerSuspended)
        }
        let onCanvas = zoneKeysOnCanvas(resolved)
        ForEach(stickRegionMaps.filter { !onCanvas.contains($0.stick) }, id: \.stick) { entry in
            RegionMapView(title: entry.stick == 0 ? String(localized: "Left stick regions") : String(localized: "Right stick regions"),
                          systemImage: "circle.dashed",
                          aspect: 1,
                          regions: entry.regions,
                          point: entry.point,
                          pointLabel: entry.stick == 0 ? String(localized: "Left stick") : String(localized: "Right stick"),
                          onPick: { region in
                              jumpToInput(InputEvent.stickRegion(stickIndex: entry.stick, id: region.id))
                          },
                          inspect: { region, swatch in
                              AnyView(inspectable(label: region.shownName, key: "stickzone-\(region.id)",
                                                  events: [InputEvent.stickRegion(stickIndex: entry.stick, id: region.id)],
                                                  draggable: false, editor: .stickZones(key: entry.stick)) { swatch })
                          })
        }
        ForEach(bandMaps.filter { !onCanvas.contains($0.key) }, id: \.key) { entry in
            let axisName = StickRegionService.axisDisplayName(entry.key - StickRegionService.bandKeyBase)
            BandMapView(title: String(localized: "\(axisName) regions"),
                        axis: entry.key - StickRegionService.bandKeyBase,
                        regions: entry.regions,
                        fraction: entry.fraction,
                        inspect: { region, swatch in
                            AnyView(inspectable(label: region.shownName, key: "stickzone-\(region.id)",
                                                events: [InputEvent.stickRegion(stickIndex: entry.key, id: region.id)],
                                                draggable: false, editor: .stickZones(key: entry.key)) { swatch })
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
        // A pad with no touchpad has no press: its button 13 is another button.
        if capabilities.touchpad { events.append(.button(capabilities.touchpadPressIndex)) }
        // A left-trackpad zone's rows carry the surface mark: without it the
        // zone read as unused and Open the editor found no row.
        events += preset.touchpadRegions.map(Self.regionEvent)
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
    func regionInfo(for input: InputEvent) -> (name: String, colorIndex: Int)? {
        if let id = input.touchpadRegionID,
           let r = preset.touchpadRegions.first(where: { $0.id == id }) {
            return (r.shownName, r.colorIndex)
        }
        if let id = input.cursorRegionID,
           let r = preset.cursorRegions.first(where: { $0.id == id }) {
            return (r.shownName, r.colorIndex)
        }
        if let id = input.stickRegionID {
            for (_, list) in preset.stickRegions {
                if let r = list.first(where: { $0.id == id }) { return (r.shownName, r.colorIndex) }
            }
        }
        return nil
    }

    /// Go to the row that binds this input. The row can live in any group,
    /// so the whole preset is searched before falling back to this slot:
    /// a screen region is usually bound once and shared, not per device.
    private func jumpToInput(_ event: InputEvent) {
        let serialized = event.serialized
        // This panel's own group first: a duplicated group holds the same
        // zone, and the first group's row opened for the second pad's panel.
        let order = [slot] + preset.joysticks.indices.filter { $0 != slot }
        let g = order.first { preset.joysticks.indices.contains($0)
            && preset.joysticks[$0].bindings.contains(where: { $0.input.serialized == serialized }) }
        let target = EditorJumpTarget(joystickIndex: g ?? slot, inputSerialized: serialized)
        // From a popover, through jump(), which closes it first.
        if openInspectorLabel != nil { jump(target) } else { onJump?(target) }
    }

    /// The display which the screen map shows, chosen by the user and
    /// remembered; empty means the map follows the pointer between displays.
    @AppStorage("InputConfig.visualizer.screenDisplay") private var screenDisplayName: String = ""
    /// The same display by its hardware, which survives a language change:
    /// macOS names a display ("Built-in Retina Display") in the app's
    /// language. Empty in choices made before 1.7, found by name then.
    @AppStorage("InputConfig.visualizer.screenDisplayID") private var screenDisplayID: String = ""

    private static func hardwareID(_ k: DisplayKey) -> String { "\(k.vendor):\(k.model):\(k.serial):\(k.uuid ?? "")" }

    private var chosenScreenDisplay: DisplayKey? {
        guard !screenDisplayName.isEmpty || !screenDisplayID.isEmpty else { return nil }
        if !screenDisplayID.isEmpty, let d = cursorService.attachedDisplays.first(where: { Self.hardwareID($0.key) == screenDisplayID }) {
            return d.key
        }
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
                        screenDisplayID = ""
                    } label: {
                        if chosenScreenDisplay == nil { Label("Follow the pointer", systemImage: "checkmark") } else { Text("Follow the pointer") }
                    }
                    Divider()
                    ForEach(cursorService.attachedDisplays) { d in
                        Button {
                            screenDisplayName = d.key.name
                            screenDisplayID = Self.hardwareID(d.key)
                        } label: {
                            if chosenScreenDisplay == d.key { Label(d.key.name, systemImage: "checkmark") } else { Text(d.key.name) }
                        }
                    }
                } label: {
                    Label(chosenScreenDisplay?.name ?? String(localized: "Follow the pointer"), systemImage: "display")
                        .font(.caption)
                }
                .fixedSize()
                .help("Which display the map shows. Follow the pointer switches as the pointer moves between displays.")
                Text(preset.cursorRegions.count == 1 ? String(localized: "1 region") : String(localized: "\(preset.cursorRegions.count) regions"))
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
                    Label(preset.cursorRegions.isEmpty ? String(localized: "Draw a screen region") : String(localized: "Draw another region"),
                          systemImage: "plus.rectangle.on.rectangle")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondaryCompact)
                // A preset holds 16 regions, as the drawing sheet does.
                .disabled(preset.cursorRegions.count >= 16)
                .help(preset.cursorRegions.count >= 16 ? String(localized: "This preset has the most regions it can hold, 16")
                      : String(localized: "Opens the editor with a Screen region row added and the drawing sheet open"))
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
                                  pointLabel: String(localized: "Pointer"),
                                  liveCursor: true,
                                  displayOverride: chosenScreenDisplay,
                                  large: true,
                                  onPick: { region in
                                      jumpToInput(InputEvent.cursorRegion(region.id))
                                  },
                                  inspect: { region, swatch in
                                      AnyView(inspectable(label: region.shownName, key: "screen-\(region.id)",
                                                          events: [InputEvent.cursorRegion(region.id)],
                                                          draggable: false, editor: .screenRegions) { swatch })
                                  })
                    // A display chosen before 1.7 is stored by name only;
                    // its hardware is added while the name still matches,
                    // so a later language change keeps the choice.
                    .onAppear {
                        if screenDisplayID.isEmpty, !screenDisplayName.isEmpty, let d = chosenScreenDisplay {
                            screenDisplayID = Self.hardwareID(d)
                        }
                    }
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

    /// True when this panel lists the preset's screen color, screen text
    /// and voice phrase rows: this slot has such a row, or no slot does
    /// yet (the watches exist without rows) and this is the first panel,
    /// so a preset with several groups shows the list once.
    private var showsScreenAndVoice: Bool {
        guard !preset.screenPixels.isEmpty || !preset.screenTexts.isEmpty || !preset.voicePhrases.isEmpty else { return false }
        let kinds: Set<InputType> = [.screenPixel, .screenText, .voicePhrase]
        func uses(_ j: JoystickMapping) -> Bool { j.bindings.contains { kinds.contains($0.input.type) } }
        // The list names every watch and phrase of the preset, so it shows
        // once, on the first group that uses them.
        return slot == (preset.joysticks.firstIndex(where: uses) ?? 0)
    }

    private var slotIsVoiceOnly: Bool {
        guard slot < preset.joysticks.count, !preset.joysticks[slot].bindings.isEmpty else { return false }
        return preset.joysticks[slot].bindings.allSatisfy { $0.input.type == .voicePhrase }
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
            guard let stick = Int(key), !StickRegionService.isBandKey(stick), !list.isEmpty else { return nil }
            let x = Double(state.axes[stick * 2] ?? 0)
            let y = Double(state.axes[stick * 2 + 1] ?? 0)
            // Axis values run -1...1; the maps are drawn in 0...1.
            return (stick, list, CGPoint(x: (x + 1) / 2, y: (y + 1) / 2))
        }
        .sorted { $0.stick < $1.stick }
    }

    /// One stick's zones or one trigger's bands, drawn large in its popover,
    /// live; clicking a zone goes to its row. Nil when it has none.
    func zoneMap(key: Int, name: String) -> AnyView? {
        let list = preset.stickRegions[String(key)] ?? []
        guard !list.isEmpty else { return nil }
        if StickRegionService.isBandKey(key) {
            let axis = key - StickRegionService.bandKeyBase
            let fraction = StickRegionService.travelFraction(axis: axis, value: state.axes[axis] ?? 0,
                                                             oneWay: StickRegionService.axisIsOneWay(axis)
                                                                || controllerService.axisReadsOneWay(slot: deviceSlot, index: axis))
            return AnyView(BandMapView(title: "", axis: axis, regions: list, fraction: fraction,
                                       onPick: { jumpToInput(InputEvent.stickRegion(stickIndex: key, id: $0.id)) },
                                       accessibilityName: String(localized: "\(name) regions")))
        }
        let x = Double(state.axes[key * 2] ?? 0), y = Double(state.axes[key * 2 + 1] ?? 0)
        return AnyView(RegionMapView(title: "", systemImage: "circle.dashed", aspect: 1, regions: list,
                                     point: CGPoint(x: (x + 1) / 2, y: (y + 1) / 2), pointLabel: name,
                                     onPick: { jumpToInput(InputEvent.stickRegion(stickIndex: key, id: $0.id)) },
                                     accessibilityName: String(localized: "\(name) regions")))
    }

    /// The sticks and axes the controller drawing shows zones inside, so
    /// their maps are not drawn again under it.
    private func zoneKeysOnCanvas(_ resolved: ResolvedLayout?) -> Set<Int> {
        guard [.controller, .auto].contains(effectiveInputKind), !slotIsMacTapsOnly, showDiagram else { return [] }
        if let r = resolved, r.layout.isComplete {
            // Only the chosen variant's controls are drawn; another
            // variant's stick would hide a map nothing shows.
            let drawn = [LayoutFace.front, .top, .back].flatMap { r.layout.controls(on: $0, variant: r.variant) }
            return Set(drawn.compactMap { c in
                ControllerCanvas.zoneStick(c) ?? ControllerCanvas.bandAxis(c).map { StickRegionService.bandKeyBase + $0 }
            })
        }
        // The standard pad's widgets: its sticks and its two triggers.
        let caps = capabilities
        var keys = Set<Int>()
        if caps.sticks.count >= 2 { keys.formUnion([0, 1]) }
        else if caps.sticks.first?.x == 0 { keys.insert(0) }
        if caps.triggers { keys.formUnion([StickRegionService.bandKeyBase + 4, StickRegionService.bandKeyBase + 5]) }
        return keys
    }

    /// A stick's zones or an axis's bands in this preset.
    func zones(key: Int) -> [TouchpadRegion] { preset.stickRegions[String(key)] ?? [] }

    /// The rows on a stick's zones or an axis's bands, for its popover.
    func zoneEvents(key: Int) -> [InputEvent] {
        zones(key: key).map { InputEvent.stickRegion(stickIndex: key, id: $0.id) }
    }

    /// This slot's gesture rows on a stick, so the stick's inspector lists them.
    func gestureEvents(stick: Int) -> [InputEvent] {
        guard slot < preset.joysticks.count else { return [] }
        var seen = Set<String>()
        return preset.joysticks[slot].bindings.map(\.input)
            .filter { $0.type == .stickGesture && $0.index == stick && seen.insert($0.serialized).inserted }
    }

    /// The preset's bands on a trigger's or one axis's travel, with the
    /// live reading as a fraction of that travel.
    private var bandMaps: [(key: Int, regions: [TouchpadRegion], fraction: Double)] {
        preset.stickRegions.compactMap { key, list in
            guard let k = Int(key), StickRegionService.isBandKey(k), !list.isEmpty else { return nil }
            let axis = k - StickRegionService.bandKeyBase
            // As the engine reads it: an axis the pad itself reads 0 to 1
            // (a wheel's clutch) counts its own travel.
            let f = StickRegionService.travelFraction(axis: axis, value: state.axes[axis] ?? 0,
                                                      oneWay: StickRegionService.axisIsOneWay(axis)
                                                        || controllerService.axisReadsOneWay(slot: deviceSlot, index: axis))
            return (k, list, f)
        }
        .sorted { $0.key < $1.key }
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
        // Remembered per device, as the drawing's own resolve asks it.
        let connected = ControllerLayoutResolver.cachedMatch(service: controllerService, slot: deviceSlot)
        let showingController = (kind == .auto || kind == .controller) && !slotIsMacTapsOnly
            && (effectiveInputKind == .controller || effectiveInputKind == .auto)
        // The menu names what is drawn: a connected pad no layout knows is
        // drawn as the standard gamepad, whatever model the group is set to.
        let padHere = info != nil
        let maps: [(kind: SlotInputKind, name: String, icon: String)] = [
            (.screen, String(localized: "Screen"), "display"), (.keyboard, String(localized: "Keyboard"), "keyboard"),
            (.touchpad, String(localized: "Touchpad"), "rectangle.and.hand.point.up.left.fill"),
            (.mouse, String(localized: "Mouse"), "computermouse"), (.midi, "MIDI", "pianokeys"),
        ]
        // Off the controller map the title names the map drawn, chosen or
        // picked on Automatic from the rows: a keyboard preset said
        // "DualSense" over a keyboard drawing.
        let shownKind = kind != .auto ? kind : effectiveInputKind
        let title = !showingController ? (maps.first { $0.kind == shownKind }?.name ?? String(localized: "Automatic"))
            : (resolvedLayout?.layout.shownName ?? connected?.shownName
                ?? (padHere ? info?.name : nil) ?? chosen?.shownName ?? String(localized: "Automatic"))
        // A model choice also brings the controller map back.
        func pick(_ id: ControllerModelID?) {
            change(slot, id)
            if kind != .auto && kind != .controller { onChangeInputKind?(slot, .controller) }
        }
        func pickAutomatic() {
            change(slot, nil)
            if kind != .auto { onChangeInputKind?(slot, .auto) }
            // A Connected pick is undone too, as the editor's Auto-detect does.
            // Also after a later map pick (Keyboard) left the kind off
            // .controller: the pad name stayed and the group kept reading it.
            if kind != .auto, group?.customName != nil { onChangeDevice?(slot, nil) }
        }
        // Search finds any model by name, its maker or its variant.
        func searchChoices() -> [MenuSearchChoice] {
            var out = [MenuSearchChoice(title: String(localized: "Automatic"), systemImage: "wand.and.stars") { pickAutomatic() }]
            out += maps.map { map in MenuSearchChoice(title: map.name, systemImage: map.icon) { onChangeInputKind?(slot, map.kind) } }
            let connectedTitle = String(localized: "Connected")
            if !connectedPadNames.isEmpty, let onChangeDevice {
                out += connectedPadNames.map { name in
                    MenuSearchChoice(title: name, path: connectedTitle) {
                        let padSlot = controllerService.slot(forDeviceNamed: name, preferring: slot)
                        change(slot, padSlot.flatMap { ControllerLayoutResolver.match(service: controllerService, slot: $0) }?.id)
                        onChangeDevice(slot, name)
                    }
                }
            } else if let connected {
                out.append(MenuSearchChoice(title: connected.shownName, path: connectedTitle) {
                    if let r = resolvedLayout, r.layout.id == connected.id, let v = r.variant {
                        pick(ControllerModelID("\(connected.id.rawValue).\(v)"))
                    } else {
                        pick(connected.id)
                    }
                })
            }
            for section in ControllerLayoutCatalog.byMaker {
                for layout in section.layouts {
                    if layout.variants.count > 1 {
                        out += layout.variants.map { v in
                            MenuSearchChoice(title: layout.shownName + ": " + LayoutText.t(v.displayName),
                                             path: section.maker.title) { pick(ControllerModelID("\(layout.id.rawValue).\(v.id)")) }
                        }
                    } else {
                        out.append(MenuSearchChoice(title: layout.shownName, path: section.maker.title) { pick(layout.id) })
                    }
                }
            }
            return out
        }
        return SearchableMenu(choices: searchChoices) {
            Button {
                pickAutomatic()
            } label: {
                if kind == .auto && group?.controllerModel == nil && !(group?.inputKind == .controller && group?.customName != nil) {
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
                    Button(connected.shownName) {
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
                                        if isChosen { Label(LayoutText.t(v.displayName), systemImage: "checkmark") } else { Text(LayoutText.t(v.displayName)) }
                                    }
                                }
                            } label: {
                                if chosen?.id == layout.id { Label(layout.shownName, systemImage: "checkmark") } else { Text(layout.shownName) }
                            }
                        } else {
                            Button {
                                pick(layout.id)
                            } label: {
                                if chosen?.id == layout.id { Label(layout.shownName, systemImage: "checkmark") } else { Text(layout.shownName) }
                            }
                        }
                    }
                } label: {
                    if chosen?.maker == section.maker { Label(section.maker.title, systemImage: "checkmark") } else { Text(section.maker.title) }
                }
            }
        } label: {
            // The app's own controller artwork, not the system symbol.
            Label { Text(title) } icon: {
                // A Menu's face ignores a resizable image's size: the
                // menu-sized glyph, as the menu items use.
                MenuIcon(name: showingController ? "gamecontroller" : (maps.first { $0.kind == shownKind }?.icon ?? "gamecontroller"))
            }
                .font(.callout)
        }
        .fixedSize()
        .help(connected != nil
              ? String(localized: "Pick a connected controller for this group to read, or a model from its maker's menu to draw it as. Automatic draws the connected controller as itself.")
              : String(localized: "What this panel shows: the controller this group is set up for, or a screen, keyboard, touchpad, mouse or MIDI map."))
        .accessibilityLabel("Visualizer map")
        .accessibilityValue(title)
    }

    /// Every connected controller by the name the editor's device menu
    /// gives it, two of one name numbered ("Xbox Wireless Controller 2").
    private var connectedPadNames: [String] {
        let gc = controllerService.connectedControllers.map { $0.vendorName ?? $0.productCategory }
        let raw = controllerService.rawHIDGamepadSlots.sorted { $0.key < $1.key }.map(\.value.displayName)
        var names = JoystickGroupView.numberedNames(gc + raw + controllerService.racingWheelNames.map(\.name))
        if controllerService.steamControllerSlot != nil { names.append("Steam Controller") }
        return names
    }

    // The controller diagram is drawn whenever we are in the controller
    // template: either a physical controller is attached, or the slot has
    // bindings to visualize. Without this, selecting Controller with nothing
    // plugged in rendered a blank panel.
    var showDiagram: Bool { info != nil || slotHasAnyBinding }

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
        case .penPressure, .penTiltX, .penTiltY, .penButton, .penEraser, .penInRange: return "pen"
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

    private var showsAccessibilityNote: Bool {
        #if DEBUG
        // Marketing capture: a test copy has no permission to show for.
        if GameControllerService.ignoresRealPads { return false }
        #endif
        return !accessibility.isTrusted
    }

    /// Shown on the keyboard and mouse templates until the app may listen.
    @ViewBuilder
    private var accessibilityNeededNote: some View {
        if showsAccessibilityNote {
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
                KeyboardMapMenu()
                Text(bound.count == 1 ? String(localized: "1 key bound") : String(localized: "\(bound.count) keys bound"))
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
                Text(boundKinds.count == 1 ? String(localized: "1 input bound") : String(localized: "\(boundKinds.count) inputs bound"))
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
                                 inspect: { kinds, name, key, part in
                                     AnyView(inspectable(label: name, key: "mouse-\(key)",
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
                Text(touchpadBindings == 1 ? String(localized: "1 input bound") : String(localized: "\(touchpadBindings) inputs bound"))
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
                touchpadSurface(pressed: capabilities.touchpad && (state.buttons[capabilities.touchpadPressIndex] ?? 0) > 0.5)
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
                Text("No touchpad inputs bound for this slot. In the editor, pick Touchpad from the input type menu, or Scan a tap or a region, or pick \"Apply default 1 to 16\" in the touchpad's Regions card for a starter grid.")
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
        if capabilities.touchpad, let name = info?.name { return String(localized: "\(name) touchpad") }
        if info != nil { return String(localized: "Controller touchpad") }
        return String(localized: "Mac trackpad")
    }

    /// The touchpad drawing, clickable as a whole (its fingers, press, taps
    /// and every zone) and zone by zone: a click on a zone lists that
    /// zone's rows. The zone targets sit beside the pad's button, not in
    /// it, so a click on a zone is the zone's alone. Both offer Touchpad
    /// Setup, where zones are drawn.
    @ViewBuilder
    func touchpadSurface(pressed: Bool) -> some View {
        ZStack {
            inspectable(label: String(localized: "Touchpad"), key: "Touchpad", events: touchpadInspectEvents, editor: .touchpadSetup) {
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
        // The pad's own coordinates: a zone on the left stays on the left.
        .environment(\.layoutDirection, .leftToRight)
    }

    /// One invisible click target over each zone the pad draws, in the
    /// same place TouchpadWidget draws it.
    /// A zone's input as its rows hold it, the left trackpad's marked s1.
    private static func regionEvent(_ region: TouchpadRegion) -> InputEvent {
        var e = InputEvent.touchpadRegion(region.id)
        if region.surface == 1 { e.touchpadSurface = 1 }
        return e
    }

    private var touchpadZoneTargets: some View {
        let w: CGFloat = 220
        let h = touchpadPadHeight
        return ZStack(alignment: .topLeading) {
            ForEach(preset.touchpadRegions) { region in
                let rect = CGRect(x: CGFloat(region.minX) * w, y: CGFloat(region.minY) * h,
                                  width: CGFloat(region.maxX - region.minX) * w,
                                  height: CGFloat(region.maxY - region.minY) * h)
                inspectable(label: region.shownName, key: "zone-\(region.id)",
                            events: [Self.regionEvent(region)],
                            draggable: false, editor: .touchpadSetup) {
                    Color.clear
                        .frame(width: max(8, rect.width), height: max(8, rect.height))
                        .contentShape(Rectangle())
                        .accessibilityLabel("\(region.shownName) region")
                }
                .help("\(region.shownName). Click to see its rows.")
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
    var deviceSlot: Int {
        guard slot < preset.joysticks.count else { return slot }
        return controllerService.effectiveSlotsCached(for: preset.joysticks)[slot] ?? slot
    }

    var capabilities: ControllerScaffold.DeviceCapabilities {
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
    func brandLabels(_ caps: ControllerScaffold.DeviceCapabilities)
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
    func inspectorName(_ match: BindingMatch) -> String {
        let slots = controllerService.effectiveSlots(for: preset.joysticks)
        let naming = controllerService.naming(forSlot: slots[match.joystickIndex] ?? match.joystickIndex,
                                              presetFamily: preset.buttonFamily)
        let input = match.binding.input
        // A stick or trackpad direction in words: "Left stick right".
        // A pad of no family still has sticks where the map draws them.
        let axisFamily = naming.family ?? (input.index < 6 && !capabilities.sticks.isEmpty ? .automatic : nil)
        if input.type == .axis, let name = ButtonNames.axisName(input.index, family: axisFamily) {
            let positive = input.axisDirection != .negative
            if name.hasSuffix(" X") { return positive ? String(localized: "\(String(name.dropLast(2))) right") : String(localized: "\(String(name.dropLast(2))) left") }
            if name.hasSuffix(" Y") { return positive ? String(localized: "\(String(name.dropLast(2))) down") : String(localized: "\(String(name.dropLast(2))) up") }
            return name
        }
        if input.type == .hat, let dir = input.hatDirection { return String(localized: "D-pad \(dir.displayName.lowercased())") }
        return ButtonNames.inputName(input, family: naming.family, model: naming.model)
    }

    /// The button that presses a trackpad drawn on these axes, or nil.
    func trackpadPress(axisX: Int, steam2015: Bool) -> Int? {
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
    static func isTrigger(_ id: String, in controls: [PlacedControl]) -> Bool {
        controls.contains { c in
            guard c.id == id, case .trigger = c.kind else { return false }
            return true
        }
    }

    /// Each drawn control's legend, name, rows and deadzone, kept across
    /// redraws (see CanvasMemo). A plain box, so filling it is no state change.
    @State var canvasMemo = CanvasMemo()

    private var resolvedLayout: ResolvedLayout? {
        guard var resolved = ControllerLayoutResolver.resolve(service: controllerService, slot: deviceSlot,
                                                              group: slot < preset.joysticks.count ? preset.joysticks[slot] : nil,
                                                              preset: preset) else { return nil }
        // An Access profile open in the editor: the caps show its functions
        // as they are edited, before anything is saved to the controller.
        if resolved.layout.id == .psAccess, let editing = accessProfileEditing {
            let caps = AccessCapStore.shared.caps(for: controllerService.accessCapsUnit(forSlot: deviceSlot))
            resolved.layout = ControllerLayout.applyingAccessCaps(
                caps, to: ControllerLayout.psAccess(ports: controllerService.accessPortDevices(forSlot: deviceSlot), profile: editing))
        }
        return resolved
    }
}

/// Re-renders only its content when the Mac's keyboard or mouse input
/// changes, so the views around it do not.
/// Redraws its content as the pointer moves over a screen map.
struct CursorRegionObserver<Content: View>: View {
    @ObservedObject private var cursorService = CursorRegionService.shared
    @ObservedObject private var pointer = CursorRegionService.shared.livePointer
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

/// The names of the trigger feel levels, 0 to 3.
enum TriggerFeelName {
    static func name(_ level: Int) -> String {
        switch level {
        // Its own key: "Light" alone is the appearance, translated as bright.
        case 1: return String(localized: "trigger-feel.light", defaultValue: "Light")
        case 2: return String(localized: "Medium")
        case 3: return String(localized: "Firm")
        default: return String(localized: "Off")
        }
    }
}


/// A popover that exists only while it is open. Every control on a drawing
/// carried an idle popover, about 18 on a DualSense, each rebuilt with the
/// panel. The anchor is a clear background in the popover's old place in
/// the chain, so it has the control's frame and environment, and the
/// control itself keeps its identity (focus, VoiceOver, its own state)
/// when the popover opens and closes.
struct OpenOnlyPopover<PopoverContent: View>: ViewModifier {
    let isOpen: Binding<Bool>
    let arrowEdge: Edge
    @ViewBuilder let popover: () -> PopoverContent

    func body(content: Content) -> some View {
        content.background {
            if isOpen.wrappedValue {
                Color.clear.popover(isPresented: isOpen, arrowEdge: arrowEdge, content: popover)
            }
        }
    }
}


/// What the controller drawing asks a panel about each control that comes
/// only from the group's rows, the preset's zones, the model drawn and the
/// names it is drawn in: its legends, its name, the rows its inputs reach,
/// its inspector's inputs and its deadzone marks. Kept by control id until
/// one of those changes: the canvas asked for each about five times a
/// frame, and every ask scanned the rows and built its strings again. The
/// caption words are not kept (a key's name follows the keyboard layout
/// and the Keys setting); they come from the kept rows on each ask.
/// Main thread only: filled and read in the panel's body.
final class CanvasMemo {
    private var rowsIn: [BindingModel] = []
    private var stickRegions: [String: [TouchpadRegion]] = [:]
    private var touchpadRegions: [TouchpadRegion] = []
    private var layout: ControllerLayout?
    private var variant: String?
    private var readPath: ReadPath?
    private var family: FaceLetters?
    private var model: ButtonNames.ModelNames = .none
    private var choice: FaceLetters = .automatic
    /// The deadzone tooltips write percents in the region's format.
    private var locale = ""
    /// Bumped each time the kept values are dropped.
    private(set) var generation = 0
    /// The group's rows by serialized input, with their place in the group.
    private(set) var rowsByKey: [String: [(offset: Int, element: BindingModel)]] = [:]
    var legends: [String: (text: String?, symbol: String?)] = [:]
    var ownLegends: [String: (text: String?, symbol: String?)] = [:]
    var names: [String: String] = [:]
    var rows: [String: [BindingModel]] = [:]
    var events: [String: [InputEvent]] = [:]
    var deadzones: [String: CanvasDeadzone?] = [:]

    /// Drops what is kept when anything it came from changed. While the
    /// preset is the same value its arrays and dictionaries compare by
    /// pointer, so an unchanged frame costs a few compares.
    func validate(rows: [BindingModel], stickRegions: [String: [TouchpadRegion]], touchpadRegions: [TouchpadRegion],
                  layout: ControllerLayout, variant: String?, readPath: ReadPath?,
                  family: FaceLetters?, model: ButtonNames.ModelNames, choice: FaceLetters) {
        let locale = Locale.current.identifier
        let same = self.layout.map { Self.same($0, layout) } == true
            && rows == rowsIn && stickRegions == self.stickRegions && touchpadRegions == self.touchpadRegions
            && variant == self.variant && readPath == self.readPath && family == self.family
            && model == self.model && choice == self.choice && locale == self.locale
        // The newest copies either way, so the next compare is a pointer check.
        rowsIn = rows
        self.stickRegions = stickRegions
        self.touchpadRegions = touchpadRegions
        self.layout = layout
        guard !same else { return }
        self.variant = variant
        self.readPath = readPath
        self.family = family
        self.model = model
        self.choice = choice
        self.locale = locale
        generation &+= 1
        rowsByKey = Dictionary(grouping: Array(rows.enumerated()), by: { $0.element.input.serialized })
        legends = [:]
        ownLegends = [:]
        names = [:]
        self.rows = [:]
        events = [:]
        deadzones = [:]
    }

    /// The value kept for a control, worked out on the first ask.
    func remember<T>(_ table: ReferenceWritableKeyPath<CanvasMemo, [String: T]>, _ id: String, _ make: () -> T) -> T {
        if let hit = self[keyPath: table][id] { return hit }
        let value = make()
        self[keyPath: table][id] = value
        return value
    }

    /// The same model as far as the kept values go: its names, its touch
    /// surfaces and every control's kind, legend, inputs and words (the
    /// Access controller's change as devices come and go on its ports).
    private static func same(_ a: ControllerLayout, _ b: ControllerLayout) -> Bool {
        a.id == b.id && a.family == b.family && a.modelNames == b.modelNames && a.modelNamesPaths == b.modelNamesPaths
            && a.touchSurfaces == b.touchSurfaces && a.controls.count == b.controls.count
            && zip(a.controls, b.controls).allSatisfy { x, y in
                x.id == y.id && x.kind == y.kind && x.face == y.face && x.shape == y.shape && x.inputs == y.inputs
                    && x.pathInputs == y.pathInputs && x.printed == y.printed && x.symbol == y.symbol
                    && x.name == y.name && x.note == y.note && x.readable == y.readable && x.variants == y.variants
            }
    }
}

/// The clock the live panel redraws on: one tick per change of what it
/// draws, bumped by the signature timer.
@MainActor @Observable
final class VisualizerRenderClock {
    var generation = 0
}

/// One 30 Hz tick for every visualizer on the page, running only while one
/// of them is watched with a pad to show. Each visualizer had two inline
/// Timer.publish clocks of its own (one per group on a preset page), which
/// fired with no pad, behind other apps and under the editor.
@MainActor
final class VisualizerTicker {
    static let shared = VisualizerTicker()
    /// Sent on the main run loop, common modes, as the inline timers were.
    let ticks = PassthroughSubject<Void, Never>()
    private var holders: Set<String> = []
    private var timer: Timer?
    private init() {}

    func hold(_ id: String) {
        holders.insert(id)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticks.send() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func release(_ id: String) {
        holders.remove(id)
        guard holders.isEmpty, let t = timer else { return }
        t.invalidate()
        timer = nil
    }
}

/// Hosts the live panel so a tick re-renders the panel alone.
struct VisualizerLiveHost<Content: View>: View {
    /// Read in the body, so a tick re-runs this host; the panel that owns
    /// the clock only writes it.
    let clock: VisualizerRenderClock
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("VisualizerLiveHost")
        #endif
        let _ = clock.generation
        content()
    }
}
