import SwiftUI
import Combine

// VirtualControllerView, the drawn controller, its widgets, inspector and region editors. Split from
// VirtualControllerView.swift, where the type and its state live, so a Debug build type-checks it in
// parallel with the rest.

extension VirtualControllerView {
    /// The real controller, drawn from its layout.
    @ViewBuilder
    func canvas(_ resolved: ResolvedLayout) -> some View {
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
        // Each control's legend, name, rows and deadzone, worked out once
        // and kept until the rows, the model or the names change: the canvas
        // asks for each about five times a frame, and every ask scanned the
        // rows and built its strings again (see CanvasMemo).
        let memo = canvasMemo
        let _ = memo.validate(rows: slot < preset.joysticks.count ? preset.joysticks[slot].bindings : [],
                              stickRegions: preset.stickRegions, touchpadRegions: preset.touchpadRegions,
                              layout: resolved.layout, variant: resolved.variant, readPath: resolved.readPath,
                              family: family, model: model, choice: choice)
        let nameOf: (PlacedControl) -> String = { c in
            memo.remember(\.names, c.id) { canvasName(physical(c), layout: layout, family: family, model: model, choice: choice) }
        }
        // Once a frame: it looks the pad up through the slot table.
        let dualSenseTriggers = drawsDualSenseTriggers
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
        // On a pad drawn with L2 and R2 the light bar sits between them, in
        // the drawing, where there is room for it at a readable size; the
        // gyro ball, when it is there too, goes under it.
        // Only between real triggers drawn on the top, with no light bar of
        // the drawing's own there (a DualShock 4's): on a fight stick or a
        // wheel "l2" and "r2" are buttons, and the chip would cover them.
        let top = layout.controls(on: .top, variant: resolved.variant)
        let lightBetween = showsLightBar && Self.isTrigger("l2", in: top) && Self.isTrigger("r2", in: top)
            && !top.contains(where: { $0.kind == .light })
        // The zones drawn are this preset's; the service holds whichever
        // preset ran or was edited last, so its pressed set can be about
        // other zones. The fingers come from the service and the drawn
        // zones are tested here, as RegionMapView does.
        let zoneLit = Self.litZones(preset.touchpadRegions, sony: sonyTouch, steam: steamTouch)
        HStack(alignment: .top, spacing: 16) {
        // The profile editor, beside the drawing it refers to.
        if resolved.layout.id == .psAccess, accessProfileEditing != nil {
            AccessProfileEditorPanel(
                profile: Binding(get: { accessProfileEditing ?? AccessControllerPortService.Profile(number: 1, name: "") },
                                 set: { accessProfileEditing = $0 }),
                original: accessEditorOriginal,
                selection: $accessEditorSelection,
                saving: accessEditorSaving,
                error: accessEditorError,
                onSave: {
                    guard let profile = accessProfileEditing else { return }
                    accessEditorSaving = true
                    accessEditorError = nil
                    let number = profile.number, device = accessEditorDevice
                    controllerService.writeAccessProfile(profile, slot: deviceSlot) { result in
                        // The editor closed, or opened on another profile
                        // or pad, while the write was out: not its answer.
                        guard accessProfileEditing?.number == number, accessEditorDevice == device else { return }
                        accessEditorSaving = false
                        switch result {
                        case .success: closeAccessEditor()
                        case .failure(let e): accessEditorError = e.localizedDescription
                        }
                    }
                },
                onCancel: { closeAccessEditor() })
            .frame(width: 330)
            .fixedSize(horizontal: true, vertical: false)
        }
        VStack(spacing: 8) {
            // The profiles the controller stores, above the drawing.
            if !printing { controllerProfilesChip(layout: resolved.layout) }
            // The preset's light bar color is set here: for a pad with a
            // light, or a drawing of one with nothing plugged in.
            if showsLightBar && !lightBetween {
                lightBarStripWidget.frame(maxWidth: 640)
            }
            ControllerCanvas(
                layout: layout,
                variant: resolved.variant,
                state: st,
                legend: { c in memo.remember(\.legends, c.id) {
                    CanvasLegend.legend(for: physical(c), in: layout, family: family, model: model, choice: choice)
                } },
                ownLegend: { c in memo.remember(\.ownLegends, c.id) {
                    CanvasLegend.legend(for: physical(c), in: layout, family: layout.family,
                                        model: resolved.layout.modelNames, choice: .automatic)
                } },
                // The rows are kept; the words are not, since a key's name
                // follows the keyboard layout and the Keys setting.
                caption: { c in
                    let rows = memo.remember(\.rows, c.id) { boundRows(for: c, layout: layout, rowsByKey: memo.rowsByKey) }
                    return triggerFeelCaption(c, base: boundCaption(rows), dualSense: dualSenseTriggers)
                },
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
                zoneOn: { zoneLit.contains($0) },
                stickZones: { preset.stickRegions[String($0)] ?? [] },
                axisBands: { preset.stickRegions[String(StickRegionService.bandKeyBase + $0)] ?? [] },
                name: nameOf,
                livePaused: !appIsActive,
                // The preset's color, else the one the pad is showing now.
                lightColor: lightBarTint ?? controllerService.shownLightColor(slot: deviceSlot).map {
                    Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255)
                },
                // The orange line on a trigger or pedal no row in this group
                // reads: the engine's default. A row's own comes with its
                // deadzone below.
                threshold: { _ in 0.25 },
                deadzone: { c in memo.remember(\.deadzones, c.id) { canvasDeadzone(c, layout: layout) } },
                between: lightBetween || gyroOnTop
                    ? ("l2", "r2", AnyView(VStack(spacing: 10) {
                        if lightBetween { lightBarStripWidget }
                        if gyroOnTop { motionWidgetIfAvailable }
                    }))
                    : nil,
                highlighted: accessEditorHighlight,
                inspect: { control, view in
                    // With the profile editor open, a socket or port on the
                    // drawing selects its row instead of opening its inspector.
                    if accessProfileEditing != nil, let key = Self.accessEditorKey(for: control) {
                        return AnyView(Button { accessEditorSelection = key } label: { view }.buttonStyle(.plain)
                            .accessibilityHint("Selects this control's row in the profile editor"))
                    }
                    let name = nameOf(control)
                    // A touch surface's zones are drawn in Touchpad Setup, a
                    // stick's or a trigger's in the stick zones sheet, on it alone.
                    let zoneKey = ControllerCanvas.zoneStick(control)
                        ?? ControllerCanvas.bandAxis(control).map { StickRegionService.bandKeyBase + $0 }
                    let editor: VisualizerRegionEditor? = layout.surface(forControl: control.id) != nil ? .touchpadSetup
                        : zoneKey.map { .stickZones(key: $0) }
                    let inner = inspectable(label: name, key: "canvas-\(control.id)",
                                            events: memo.remember(\.events, control.id) { canvasEvents(control, layout: layout) },
                                            draggable: false,
                                            note: canvasNote(control), editor: editor,
                                            zoneMap: zoneKey.flatMap { zoneMap(key: $0, name: name) }) { view }
                    // An Access socket or the stick: its cap from a right-click.
                    if layout.id == .psAccess, let capMenu = accessCapMenu(for: control) {
                        return AnyView(inner.contextMenu { capMenu })
                    }
                    return AnyView(inner)
                },
                // What the closures above give a control changes only with
                // the kept values, the profile editor and edit mode.
                cellToken: memo.generation &* 4 &+ (accessProfileEditing != nil ? 2 : 0) &+ (editMode ? 1 : 0),
                openControl: openInspectorLabel.flatMap { $0.hasPrefix("canvas-") ? String($0.dropFirst(7)) : nil })
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
                Text(LayoutText.t(why)).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            case .full:
                EmptyView()
            }
            if !stray.isEmpty {
                let strayNames = stray.map { ButtonNames.label($0, family: family, model: naming.family == nil ? layout.modelNames : naming.model) }.joined(separator: ", ")
                // Strays are numbered by the read path, so the path's names.
                Text(String(localized: "Also reported: \(strayNames)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
        #if DEBUG
        // Opens profile N (1...3) in the editor, for a capture or a check
        // without a click: Marketing/tools/post inputconfig.debug.accessprofile 2
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.accessprofile"))) { note in
            let number = Int((note.object as? String) ?? "") ?? 1
            let state = controllerService.accessProfileState(forSlot: deviceSlot)
            if let profile = state.profiles[number] { openAccessEditor(profile) } else { closeAccessEditor() }
        }
        .onAppear { DebugHookRelay.shared.ensure("inputconfig.debug.accessprofile") }
        #endif
    }

    /// The drawn zones a finger is inside, by surface: a Sony pad's from
    /// the shared service, a Steam Controller's right pad (surface 0) and
    /// left pad (surface 1) from their own instances.
    private static func litZones(_ zones: [TouchpadRegion], sony: Bool, steam: Bool) -> Set<UUID> {
        guard !zones.isEmpty, sony || steam else { return [] }
        func points(_ tp: TouchpadService) -> [CGPoint] {
            let size = tp.nominalSurfaceSize
            return (0..<2).compactMap { f in
                tp.currentPosition(finger: f).map {
                    CGPoint(x: Double($0.x) / Double(max(1, size.width)), y: Double($0.y) / Double(max(1, size.height)))
                }
            }
        }
        var bySurface: [Int: [CGPoint]] = [:]
        if sony { bySurface[0] = points(TouchpadService.shared) }
        if steam {
            bySurface[0, default: []] += points(TouchpadService.steamRight)
            bySurface[1] = points(TouchpadService.second)
        }
        return Set(zones.filter { z in
            (bySurface[z.surface == 1 ? 1 : 0] ?? []).contains { z.contains(normalizedX: $0.x, y: $0.y) }
        }.map(\.id))
    }

    /// The pad the slot reads, as the profile editor remembers it.
    var accessEditorDeviceKey: String {
        let pad = deviceSlot < controllerService.connectedControllers.count
            ? ObjectIdentifier(controllerService.connectedControllers[deviceSlot]).hashValue : 0
        return "\(deviceSlot)|\(pad)|\(controllerService.accessProfileState(forSlot: deviceSlot).connected)"
    }

    private func openAccessEditor(_ profile: AccessControllerPortService.Profile) {
        accessProfileEditing = profile
        accessEditorOriginal = profile
        accessEditorDevice = accessEditorDeviceKey
        accessEditorSelection = "socket1"
        accessEditorError = nil
        // A reply for another profile is dropped by design, so it would
        // never clear this and Save stayed off with its spinner turning.
        accessEditorSaving = false
    }

    func closeAccessEditor() {
        accessProfileEditing = nil
        accessEditorOriginal = nil
        accessEditorDevice = nil
        accessEditorSelection = nil
        accessEditorError = nil
        accessEditorSaving = false
    }

    /// The editor row a drawn control belongs to, when it has one.
    private static func accessEditorKey(for c: PlacedControl) -> String? {
        if c.id.hasPrefix("socket") || c.id == "center" || c.id == "stick" { return c.id }
        if c.face == .top, c.id.count == 2, c.id.hasPrefix("e") { return c.id }
        return nil
    }

    /// The cap picker for an Access socket or the stick, for its
    /// right-click menu; nil for any other control.
    private func accessCapMenu(for control: PlacedControl) -> AnyView? {
        let unit = controllerService.accessCapsUnit(forSlot: deviceSlot)
        let caps = AccessCapStore.shared.caps(for: unit)
        if control.id == "stick" { return AnyView(AccessCapsMenu.stickPicker(caps: caps, unit: unit)) }
        guard control.id.hasPrefix("socket"), let n = Int(control.id.dropFirst(6)) else { return nil }
        return AnyView(AccessCapsMenu.socketPicker(n, caps: caps, unit: unit))
    }

    private var accessEditorHighlight: Set<String> {
        guard accessProfileEditing != nil, let key = accessEditorSelection else { return [] }
        return [key]
    }

    // MARK: - Stored profiles and trigger feel

    /// The chip above an Access controller's or a DualSense Edge's drawing.
    @ViewBuilder
    private func controllerProfilesChip(layout: ControllerLayout) -> some View {
        if layout.id == .psAccess {
            let state = controllerService.accessProfileState(forSlot: deviceSlot)
            if state.connected {
                HStack(spacing: 8) {
                AccessProfilesChip(state: state, isPresented: $showProfilesPopover,
                                   onUse: { number, done in controllerService.setAccessProfile(number, slot: deviceSlot, completion: done) },
                                   onEdit: { profile in
                                       showProfilesPopover = false
                                       // An open editor with edits, or a write
                                       // in flight, is not replaced unasked:
                                       // its edits vanished with no question.
                                       if accessEditorSaving || (accessProfileEditing != nil && accessProfileEditing != accessEditorOriginal) {
                                           let line = String(localized: "Save or cancel the profile being edited first.")
                                           AccessibilityNotification.Announcement(line).post()
                                           accessEditorError = line
                                           return
                                       }
                                       openAccessEditor(profile)
                                   },
                                   onRefresh: { controllerService.refreshAccessProfiles(forSlot: deviceSlot) })
                // The caps beside the chip: physical, kept on this Mac,
                // nothing written to the controller.
                AccessCapsMenu(unit: controllerService.accessCapsUnit(forSlot: deviceSlot))
                Spacer(minLength: 0)
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
        } else if layout.id == .dualSenseEdge {
            let profiles = controllerService.edgeProfiles(forSlot: deviceSlot)
            if !profiles.isEmpty {
                EdgeProfilesChip(profiles: profiles, isPresented: $showProfilesPopover)
                    .frame(maxWidth: 640, alignment: .leading)
            }
        }
    }

    /// The pad drawn is a DualSense or DualSense Edge that is here, so its
    /// triggers can be given a feel.
    private var drawsDualSenseTriggers: Bool {
        guard let info else { return false }
        return info.brand == .dualSense || info.name.localizedCaseInsensitiveContains("dualsense")
    }

    /// Which trigger an inspector key is, when it is one on a DualSense.
    private func triggerSide(forInspectorKey key: String?) -> Bool? {
        guard drawsDualSenseTriggers else { return nil }
        switch key {
        case "canvas-l2": return true
        case "canvas-r2": return false
        default: return nil
        }
    }

    /// The adaptive trigger's resistance while this preset runs.
    @ViewBuilder
    private func triggerFeelRow(left: Bool) -> some View {
        let level = (left ? preset.triggerFeelLeft : preset.triggerFeelRight) ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text("Trigger feel")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Trigger feel", selection: Binding(
                get: { level },
                set: { onChangeTriggerFeel?(left, $0) })) {
                ForEach(0...3, id: \.self) { Text(TriggerFeelName.name($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .disabled(onChangeTriggerFeel == nil)
            Text("Resistance across the pull while this preset runs; the trigger is let go when it stops.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A trigger with a feel says so under the drawing, after its rows.
    /// `dualSense` is `drawsDualSenseTriggers`, read once a frame.
    private func triggerFeelCaption(_ c: PlacedControl, base: String?, dualSense: Bool) -> String? {
        guard dualSense, c.id == "l2" || c.id == "r2" else { return base }
        let level = (c.id == "l2" ? preset.triggerFeelLeft : preset.triggerFeelRight) ?? 0
        guard level > 0 else { return base }
        let feel = String(localized: "\(TriggerFeelName.name(level)) feel")
        return base.map { "\($0), \(feel.lowercased())" } ?? feel
    }

    /// What a control's inspector lists: its own inputs, and for a touch
    /// surface every finger, zone and gesture row it can carry.
    private func canvasEvents(_ c: PlacedControl, layout: ControllerLayout) -> [InputEvent] {
        var events = c.inputs.inspectEvents()
        // A stick's zones and gestures, a trigger's bands: their rows too.
        if let stick = ControllerCanvas.zoneStick(c) {
            events += (preset.stickRegions[String(stick)] ?? []).map { InputEvent.stickRegion(stickIndex: stick, id: $0.id) }
            events += gestureEvents(stick: stick)
        } else if let axis = ControllerCanvas.bandAxis(c) {
            let key = StickRegionService.bandKeyBase + axis
            events += (preset.stickRegions[String(key)] ?? []).map { InputEvent.stickRegion(stickIndex: key, id: $0.id) }
        }
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
        // Each pad's own regions: the left Steam trackpad's carry its surface.
        if spec.surface <= 1 {
            events += preset.touchpadRegions.filter { ($0.surface == 1) == (spec.surface == 1) }
                .map { onSurface(InputEvent.touchpadRegion($0.id)) }
        }
        events += TouchpadGestureKind.allCases.map { onSurface(.touchpadGesture($0)) }
        return events
    }

    /// The line under a control's inspector title: when it is read only in
    /// some setups, why; else the layout's note on it.
    private func canvasNote(_ c: PlacedControl) -> String? {
        if case .conditional(let why) = c.readable { return LayoutText.t(why) }
        return c.note.map(LayoutText.t)
    }

    /// A control's name for its inspector title and VoiceOver.
    private func canvasName(_ c: PlacedControl, layout: ControllerLayout, family: FaceLetters?,
                            model: ButtonNames.ModelNames, choice: FaceLetters) -> String {
        if let spec = layout.surface(forControl: c.id) { return LayoutText.t(spec.name) }
        if let name = c.name { return LayoutText.t(name) }
        if let dir = c.inputs.hatDirection { return String(localized: "D-pad \(dir.displayName.lowercased())") }
        switch c.kind {
        case .stick:
            if let x = c.inputs.axes.first?.index, let n = ButtonNames.axisName(x, family: family ?? .automatic),
               n.hasSuffix(" X") { return String(n.dropLast(2)) }
            return String(localized: "Stick")
        case .dpad: return String(localized: "D-pad")
        case .trigger:
            // The analog trigger, not its digital copy's "(digital)" name.
            if let a = c.inputs.axes.first?.index, let n = ButtonNames.axisName(a, family: family ?? .automatic) { return n }
            if let d = c.inputs.digitalCopy, let short = ButtonNames.short(d, family: family, model: model) { return short }
            return c.printed ?? String(localized: "Trigger")
        default:
            if let b = c.inputs.buttons.first {
                // The family's full name where it has one ("Left Fn (Edge)"
                // for a button printed "Fn"); the printed legend otherwise.
                let label = ButtonNames.label(b, family: family, model: model, choice: choice)
                // The legend too where the name is only a number: the app's
                // own fallback, or a model's English "Button 3".
                if let printed = c.printed, label == ButtonNames.fallbackLabel(b) || label.hasPrefix("Button ")
                    || label == LayoutText.t("Button \(b + 1)") { return printed }
                return label
            }
            if let printed = c.printed { return CanvasLegend.printedWord(printed) }
            // The id in words, never the raw id.
            return LayoutText.t(CanvasLegend.words(c.id))
        }
    }

    /// The rows in this group a control's inputs reach, in row order.
    private func boundRows(for c: PlacedControl, layout: ControllerLayout,
                           rowsByKey: [String: [(offset: Int, element: BindingModel)]]) -> [BindingModel] {
        guard slot < preset.joysticks.count else { return [] }
        // In row order, as the full scan gave them.
        let keys = Set(canvasEvents(c, layout: layout).map(\.serialized))
        return keys.flatMap { rowsByKey[$0] ?? [] }.sorted { $0.offset < $1.offset }.map(\.element)
    }

    /// The function a control is bound to in this group, for its caption:
    /// the row's note, else its outputs.
    private func boundCaption(_ rows: [BindingModel]) -> String? {
        guard !rows.isEmpty else { return nil }
        // The first row with something to say: a macro-only row first left
        // the caption empty, or a bare " +1" hiding the working row.
        func caption(_ row: BindingModel) -> String {
            let note = ShippedText.t((row.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            if !note.isEmpty { return note }
            for list in [row.outputs, row.holdOutputs ?? [], row.doubleTapOutputs ?? []] where !list.isEmpty {
                return OutputAction.names(list).joined(separator: " + ")
            }
            if let steps = row.macroSteps, !steps.isEmpty {
                return steps.count == 1 ? String(localized: "Runs a macro of 1 step") : String(localized: "Runs a macro of \(steps.count) steps")
            }
            return ""
        }
        // A D-pad's directions are four controls in one drawing, often on
        // unrelated things: each one says its own, not "Up +3".
        if rows.count > 1, rows.allSatisfy({ $0.input.type == .hat && $0.input.hatDirection != nil }) {
            let lines = rows.compactMap { row -> String? in
                let text = caption(row)
                guard !text.isEmpty, let way = row.input.hatDirection?.displayName else { return nil }
                return String(localized: "\(way): \(text)")
            }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
        }
        guard let text = rows.lazy.map(caption).first(where: { !$0.isEmpty }) else { return nil }
        return rows.count > 1 ? text + " +\(rows.count - 1)" : text
    }

    @ViewBuilder
    var controllerWidgets: some View {
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
            // Not for a wheel's pedals or a flight stick's lone slider on a
            // trigger slot: they get bars of their own below.
            let axesKnown = caps.steering || caps.combinedPedal || !caps.pedals.isEmpty || caps.loneTrigger || !caps.extraAxes.isEmpty
            if !axesKnown, (st.axes[4] ?? 0) != 0 || (st.axes[5] ?? 0) != 0 { caps.triggers = true }
            // Not the Steam Controller's "left pad and stick both in use"
            // bit, which is a state, not a button, and showed as "Button 22".
            for index in st.buttons.keys where !caps.buttons.contains(where: { $0.index == index })
                && !(isSteam && index == SteamControllerButton.stickActive.rawValue) {
                caps.buttons.append((index, String(localized: "Button \(index)")))
            }
            if caps.sticks.isEmpty, !axesKnown, st.axes[0] != nil || st.axes[1] != nil {
                caps.sticks = [("Left stick", 0, 1, String(localized: "Left stick"))]
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
                            inspectable(label: labels.shoulder[6] ?? "LT", key: "LT",
                                        events: [.axis(4, direction: .positive)] + zoneEvents(key: StickRegionService.bandKeyBase + 4),
                                        editor: .stickZones(key: StickRegionService.bandKeyBase + 4),
                                        zoneMap: zoneMap(key: StickRegionService.bandKeyBase + 4, name: labels.shoulder[6] ?? "LT")) {
                                TriggerWidget(label: labels.shoulder[6] ?? "LT", value: state.axes[4] ?? 0,
                                              threshold: thresholdForAxis(4, dir: .positive),
                                              tint: .blue, bands: zones(key: StickRegionService.bandKeyBase + 4))
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
                                    menuPill(label: labels.menu[index] ?? String(localized: "Menu"), index: std(index), key: "menu-\(index)")
                                }
                            }
                        }
                        if caps.gyro { motionWidgetIfAvailable }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        if caps.triggers {
                            inspectable(label: labels.shoulder[7] ?? "RT", key: "RT",
                                        events: [.axis(5, direction: .positive)] + zoneEvents(key: StickRegionService.bandKeyBase + 5),
                                        editor: .stickZones(key: StickRegionService.bandKeyBase + 5),
                                        zoneMap: zoneMap(key: StickRegionService.bandKeyBase + 5, name: labels.shoulder[7] ?? "RT")) {
                                TriggerWidget(label: labels.shoulder[7] ?? "RT", value: state.axes[5] ?? 0,
                                              threshold: thresholdForAxis(5, dir: .positive),
                                              tint: .red, bands: zones(key: StickRegionService.bandKeyBase + 5))
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
                        inspectable(label: String(localized: "D-pad"), key: "D-pad", events: [
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
                            ] + gestureEvents(stick: 0) + zoneEvents(key: 0), editor: .stickZones(key: 0),
                               zoneMap: zoneMap(key: 0, name: caps.sticks[0].label)) {
                                StickWidget(label: caps.sticks[0].label,
                                            x: state.axes[0] ?? 0,
                                            y: state.axes[1] ?? 0,
                                            pressed: (state.buttons[std(11)] ?? 0) > 0.5,
                                            zones: zones(key: 0))
                            }
                            // The 2015 Steam Controller's right "stick" is its
                            // right trackpad, pressed on its own button.
                            let rightPress = isSteam ? SteamControllerButton.rightPadClick.rawValue : 12
                            inspectable(label: caps.sticks[1].label, key: "Right stick", events: [
                                .axis(2, direction: .positive), .axis(2, direction: .negative),
                                .axis(3, direction: .positive), .axis(3, direction: .negative),
                                .button(rightPress)
                            ] + gestureEvents(stick: 1) + zoneEvents(key: 1), editor: .stickZones(key: 1),
                               zoneMap: zoneMap(key: 1, name: caps.sticks[1].label)) {
                                StickWidget(label: caps.sticks[1].label,
                                            x: state.axes[2] ?? 0,
                                            y: state.axes[3] ?? 0,
                                            pressed: (state.buttons[rightPress] ?? 0) > 0.5,
                                            zones: zones(key: 1))
                            }
                            // Further surfaces: the Steam Controllers'
                            // trackpads (the 2015 left one on 6 and 7, the
                            // 2026 pair on 6 to 9), each with its press.
                            ForEach(Array(caps.sticks.dropFirst(2).enumerated()), id: \.offset) { _, surface in
                                let press = trackpadPress(axisX: surface.x, steam2015: isSteam)
                                inspectable(label: surface.label, key: "surface-\(surface.x)-\(surface.y)", legacyKey: surface.label, events: [
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
                    inspectable(label: only.label, key: "stick-\(only.x)-\(only.y)", legacyKey: only.label, events: [
                        .axis(only.x, direction: .positive), .axis(only.x, direction: .negative),
                        .axis(only.y, direction: .positive), .axis(only.y, direction: .negative)
                    ] + (only.x == 0 ? gestureEvents(stick: 0) + zoneEvents(key: 0) : []),
                       editor: only.x == 0 ? .stickZones(key: 0) : nil,
                       zoneMap: only.x == 0 ? zoneMap(key: 0, name: only.label) : nil) {
                        StickWidget(label: only.label,
                                    x: state.axes[only.x] ?? 0,
                                    y: state.axes[only.y] ?? 0,
                                    pressed: false,
                                    zones: only.x == 0 ? zones(key: 0) : [])
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
                let physical = Set(plan.buttonIndices)
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
                            Text(caps.family == .steamController2026 ? String(localized: "Right trackpad (touch)")
                                 : (info.map { String(localized: "\($0.name) touchpad") } ?? String(localized: "Controller touchpad")))
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
            var extraAxes = controllerService.extraAxesSnapshot(for: deviceSlot).filter { !drawnAxes.contains($0.index) }
            // An axis with no stick or trigger to draw it (a flight stick's
            // twist on 2 with nothing on 3) gets a bar too.
            // A wheel's steering and pedals too, drawn at rest, and every
            // listed axis before its first report.
            let _ = {
                var listed = caps.extraAxes
                if caps.steering { listed.append((0, String(localized: "Steering"))) }
                if caps.combinedPedal { listed.append((1, String(localized: "Pedals"))) }
                listed += caps.pedals
                for a in listed where !drawnAxes.contains(a.index) {
                    if let at = extraAxes.firstIndex(where: { $0.index == a.index }) {
                        extraAxes[at] = GameControllerService.ExtraAxis(label: a.name, index: a.index, value: extraAxes[at].value)
                    } else {
                        extraAxes.append(GameControllerService.ExtraAxis(label: a.name, index: a.index, value: state.axes[a.index] ?? 0))
                    }
                }
                extraAxes.sort { $0.index < $1.index }
            }()
            if !extraAxes.isEmpty {
                extraAxesWidget(axes: extraAxes, pedalAxes: Set(caps.pedals.map(\.index)),
                                // A 2026 trackpad's pressure (10 and 11) only
                                // rises; its X and Y (6 to 9) go both ways.
                                pressureAxes: caps.family == .steamController2026 ? [10, 11] : [])
            }

            // Hats past the first: a flight stick's POV hats, or a pad with
            // two D-pads. Only the first was drawn, so the others fired
            // rows with nothing on screen.
            let extraHats = state.hats.keys.filter { $0 > 0 }.sorted()
            if showDiagram, !extraHats.isEmpty {
                HStack(spacing: 18) {
                    ForEach(extraHats, id: \.self) { index in
                        // The number the rows use (Hat 1 is the second hat).
                        let label = String(localized: "Hat \(index)")
                        VStack(spacing: 4) {
                            inspectable(label: label, key: "Hat \(index + 1)", events: [
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
    private func extraAxesWidget(axes: [GameControllerService.ExtraAxis], pedalAxes: Set<Int> = [], pressureAxes: Set<Int> = []) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra axes")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(axes) { axis in
                // Clicked like any other control, to see and add its rows.
                // A pedal or trigger-slot axis reads only one way.
                let oneWay = axis.index == 4 || axis.index == 5 || pedalAxes.contains(axis.index) || pressureAxes.contains(axis.index)
                inspectable(label: axis.label, key: "axis-\(axis.index)",
                            events: oneWay ? [.axis(axis.index, direction: .positive)]
                                : [.axis(axis.index, direction: .positive), .axis(axis.index, direction: .negative)],
                            draggable: false) {
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
                    Text(String(format: "%+.2f", locale: .current, axis.value))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.hint)
                        .frame(minWidth: 44, alignment: .trailing)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(axis.label)
                .accessibilityValue(SpokenLive.axis(axis.value))
                }
            }
        }
        .padding(.top, 4)
    }

    /// True when the extra button has a real, human-meaningful name
    /// (PS, Home, Mute, paddles, FN). False when it's a raw HID
    /// gamepad's "Button N" / "Btn N" fallback label - those become
    /// round placeholder icons instead.
    private func isNamedExtra(_ extra: GameControllerService.ExtraButton) -> Bool {
        // The app's own fallback name, in the app's language.
        if extra.label == ButtonNames.fallbackLabel(extra.index) { return false }
        // A model's numbered name ("Button 14" on a Logitech wheel), translated.
        if extra.label == LayoutText.t("Button \(extra.index + 1)") { return false }
        // Generic names a device reports itself, in English.
        let lower = extra.label.lowercased()
        if lower.hasPrefix("button ") { return false }
        if lower.hasPrefix("btn ") { return false }
        return true
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
        let named = extras.filter { isNamedExtra($0) }
        let unknown = extras.filter { !isNamedExtra($0) }
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
                            inspectable(label: extra.label, key: "extra-\(extra.index)", legacyKey: extra.label, events: [.button(extra.index)]) {
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
                    // Wrapped, so a 32 or 64 button device stays inside the map.
                    WrappingHStackLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(unknown) { btn in
                            unknownButtonPlaceholder(btn)
                        }
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
            .foregroundStyle(pressed ? (pressedOutline ? Color.black : Color.white) : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(pressed ? 0.85 : 0.15)))
            .overlay(Capsule().stroke(tint.opacity(pressed ? 1 : 0.35), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: pressed)
            .accessibilityLabel(label)
            .accessibilityValue(pressed ? String(localized: "pressed") : String(localized: "released"))
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
        inspectable(label: "extra-\(button.index)", title: String(localized: "Button \(button.index)"),
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
                    .foregroundStyle(button.pressed ? (pressedOutline ? Color.black : Color.white) : Color.primary)
            }
            .frame(width: 28, height: 28)
            .help("Unknown extra button \(button.index): drag in 'Customize layout' to reposition")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Extra button \(button.index)")
            .accessibilityValue(button.pressed ? String(localized: "pressed") : String(localized: "released"))
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
            // In the drawing, at its captions' size, and only as wide as the
            // gap between the triggers: the words go first when it is tight.
            LightBarChipLabel(off: lightBarOff, rainbow: lightBarRainbow, tint: lightBarTint,
                              leftToSystem: lightBarLeftToSystem)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .help(lightBarTint == nil && !lightBarRainbow && !lightBarOff
              ? String(localized: "Pick a light bar color for this preset")
              : String(localized: "Edit this preset's light bar color"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Light bar color")
        .accessibilityValue(lightBarLeftToSystem ? String(localized: "left to macOS, see Settings")
                            : lightBarOff ? String(localized: "off") : lightBarRainbow ? String(localized: "rainbow") : lightBarTint == nil ? String(localized: "not set") : String(localized: "set"))
        .accessibilityHint("Opens the light bar color picker")
        .accessibilityAddTraits(.isButton)
        .spotlightAnchor(SpotlightID.lightBarStrip)
        .popover(isPresented: $showLightBarPopover, arrowEdge: .top) {
            // Inside the left-to-right controller drawing; the picker reads
            // in the app's own direction.
            trailing()
                .environment(\.layoutDirection, appDirection)
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
            inspectable(label: String(localized: "Motion"), key: "Motion", events: motionInspectEvents) {
                MotionWidget(
                    state: state,
                    integratedRoll: integratedRoll,
                    integratedPitch: integratedPitch,
                    integratedYaw: integratedYaw
                )
                .spotlightAnchor(SpotlightID.motionWidget)
            }
        }
    }

    /// Wraps any widget in a Button whose popover anchors at the widget's
    /// own bounds - so taps open a popover *right there* instead of
    /// floating to the middle of the window. In edit mode the widget
    /// instead participates in drag-to-rearrange: each widget remembers an
    /// (x, y) offset from its structural position and applies it here.
    @ViewBuilder
    func inspectable<Content: View>(
        label: String, title: String? = nil, key: String? = nil, legacyKey: String? = nil, events: [InputEvent],
        draggable: Bool = true, note: String? = nil, editor: VisualizerRegionEditor? = nil,
        zoneMap: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // A stable key for the saved position and the open popover, so a
        // widget whose label follows the family (LB, L1, L) keeps both.
        let key = key ?? label
        // The controller drawing places every control where it really is,
        // so it neither drags nor takes a saved offset.
        // A position saved before 1.7 under the widget's label still counts
        // (the label is the 1.6 key in English) until the widget is dragged again.
        let persistedOffset = draggable ? (dragOffsets[key] ?? legacyKey.flatMap { dragOffsets[$0] } ?? .zero) : .zero
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
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            liveDrag = (key, value.translation)
                        }
                        .onEnded { value in
                            let base = dragOffsets[key] ?? legacyKey.flatMap { dragOffsets[$0] } ?? .zero
                            dragOffsets[key] = CGSize(
                                width: base.width + value.translation.width,
                                height: base.height + value.translation.height
                            )
                            liveDrag = nil
                            persistOffsets()
                        }
                )
                // Moved without dragging: named actions for VoiceOver and
                // Switch Control, a right-click menu for pointer, dwell and
                // Voice Control users. Ten points a step.
                // The widget's own spoken name comes through: the layout
                // key read "extra-12" and the bare PlayStation glyphs.
                .accessibilityElement(children: .combine)
                .accessibilityHint("Drag to move, or use the move actions")
                // Keyboard: Tab to a widget, arrows move it.
                .focusable()
                .onMoveCommand { direction in
                    switch direction {
                    case .left: nudge(key, legacyKey, dx: -10, dy: 0)
                    case .right: nudge(key, legacyKey, dx: 10, dy: 0)
                    case .up: nudge(key, legacyKey, dx: 0, dy: -10)
                    case .down: nudge(key, legacyKey, dx: 0, dy: 10)
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: "Move left") { nudge(key, legacyKey, dx: -10, dy: 0) }
                .accessibilityAction(named: "Move right") { nudge(key, legacyKey, dx: 10, dy: 0) }
                .accessibilityAction(named: "Move up") { nudge(key, legacyKey, dx: 0, dy: -10) }
                .accessibilityAction(named: "Move down") { nudge(key, legacyKey, dx: 0, dy: 10) }
                .contextMenu {
                    Button("Move Left") { nudge(key, legacyKey, dx: -10, dy: 0) }
                    Button("Move Right") { nudge(key, legacyKey, dx: 10, dy: 0) }
                    Button("Move Up") { nudge(key, legacyKey, dx: 0, dy: -10) }
                    Button("Move Down") { nudge(key, legacyKey, dx: 0, dy: 10) }
                }
                // Last, so the focus ring, the right-click area and the
                // accessibility frame follow the widget where it is drawn.
                .offset(totalOffset)
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
            .modifier(OpenOnlyPopover(isOpen: isOpen, arrowEdge: .top) {
                inspectorContent(label: title ?? label, key: key, events: events, note: note, editor: editor, zoneMap: zoneMap)
                    .environment(\.layoutDirection, appDirection)
            })
        }
    }

    // MARK: - Layout persistence

    /// Reload saved offsets for the currently-selected controller model.
    /// Called on appear and whenever the slot changes.
    func loadOffsets() {
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
    /// Moves a widget in Edit Layout by a step, as a drag would.
    private func nudge(_ key: String, _ legacyKey: String?, dx: CGFloat, dy: CGFloat) {
        let base = dragOffsets[key] ?? legacyKey.flatMap { dragOffsets[$0] } ?? .zero
        dragOffsets[key] = CGSize(width: base.width + dx, height: base.height + dy)
        persistOffsets()
    }

    func persistOffsets() {
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
                .overlay(Capsule().stroke(pressed ? Color.green : Color.secondary.opacity(0.3), lineWidth: pressed && pressedOutline ? 2 : 0.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(pressed ? String(localized: "pressed") : String(localized: "released"))
        }
    }

    // MARK: - Inspector (dead helper kept for symmetry - per-widget
    // popovers anchor themselves via inspectable() instead).

    /// A binding match enriched with the joystick group it lives in and its
    /// 1-based position within that group, so the popover can show "#3" next
    /// to each row and jump back to the exact same row in the editor.
    struct BindingMatch: Identifiable {
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
    fileprivate func inspectorContent(label: String, key: String? = nil, events: [InputEvent], note: String? = nil,
                                      editor: VisualizerRegionEditor? = nil, zoneMap: AnyView? = nil) -> some View {
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
            if key == "Motion" {
                gyroResetActionRow
                Divider()
            }
            // A stick's or a trigger's zones, large enough to read.
            if let zoneMap { zoneMap }
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
            if let editor, onJump != nil {
                Button {
                    openRegionEditor(editor)
                } label: {
                    Label(editor.buttonTitle, systemImage: editor.systemImage)
                        .font(.callout)
                }
                .buttonStyle(.solidSecondaryCompact)
                .help(editor == .touchpadSetup ? String(localized: "Draw and name this preset's touchpad regions")
                      : editor == .screenRegions ? String(localized: "Draw and name this preset's screen regions")
                      : editor.buttonTitle == String(localized: "Edit trigger regions")
                        ? String(localized: "Draw and name this preset's trigger regions")
                        : String(localized: "Draw and name this preset's stick regions"))
            }
            // A DualSense trigger's feel: a setting of this preset, so it
            // comes after what the trigger does, under its own line.
            if let left = triggerSide(forInspectorKey: key) {
                Divider()
                triggerFeelRow(left: left)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// The device this map shows and how many rows use the control.
    private func inspectorSubtitle(count: Int) -> String {
        let device = capabilities.deviceName
        if device.isEmpty {
            return count == 0 ? String(localized: "Not used in this preset") : count == 1 ? String(localized: "1 row in this preset") : String(localized: "\(count) rows in this preset")
        }
        return count == 0 ? String(localized: "\(device), not used in this preset") : count == 1 ? String(localized: "\(device), 1 row in this preset") : String(localized: "\(device), \(count) rows in this preset")
    }

    /// One row of the inspector: what the control does, in words. The
    /// row's own note leads when it has one, the outputs follow, then the
    /// ways it fires besides a plain press.
    private func inspectorRow(_ match: BindingMatch, widgetHasSeveralInputs: Bool) -> some View {
        let b = match.binding
        let outputs = OutputAction.names(b.outputs).joined(separator: " + ")
        let note = ShippedText.t((b.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        var details: [String] = []
        if !note.isEmpty, !outputs.isEmpty { details.append(String(localized: "Sends \(outputs)")) }
        if let hold = b.holdOutputs, !hold.isEmpty {
            details.append(String(localized: "Held: \(OutputAction.names(hold).joined(separator: " + "))"))
        }
        if let double = b.doubleTapOutputs, !double.isEmpty {
            details.append(String(localized: "Double tap: \(OutputAction.names(double).joined(separator: " + "))"))
        }
        if let triple = b.tripleTapOutputs, !triple.isEmpty {
            details.append(String(localized: "Triple tap: \(OutputAction.names(triple).joined(separator: " + "))"))
        }
        if !b.modifiers.isEmpty {
            // The row's own group's pad, as its name above uses: another
            // group's Xbox row said "L1" in a DualSense panel.
            let rowSlot = controllerService.effectiveSlots(for: preset.joysticks)[match.joystickIndex] ?? match.joystickIndex
            let family = controllerService.naming(forSlot: rowSlot, presetFamily: preset.buttonFamily)
            let held = b.modifiers
                .map { ButtonNames.inputName($0, family: family.family, model: family.model) }
            details.append(String(localized: "Only while holding \(LocalizedList.and(held))"))
        }
        if let steps = b.macroSteps, !steps.isEmpty { details.append(steps.count == 1 ? String(localized: "Runs a macro of 1 step") : String(localized: "Runs a macro of \(steps.count) steps")) }
        // The press modes the engine runs: toggle plus turbo is the auto
        // clicker, and a repeat count counts only on a plain press or a
        // macro (as the editor's own summary has it).
        let toggles = b.toggleMode == true, turbo = b.turboEnabled == true
        if toggles && turbo {
            details.append(String(localized: "Repeats until pressed again"))
        } else {
            if toggles { details.append(String(localized: "Toggles: press once to hold, again to let go")) }
            if turbo { details.append(String(localized: "Repeats rapidly while held")) }
        }
        let repeatApplies = b.macroSteps?.isEmpty == false
            || (!toggles && !turbo && b.holdOutputs == nil && b.doubleTapOutputs == nil && b.tripleTapOutputs == nil)
        if let n = b.repeatCount, n > 1, repeatApplies { details.append(String(localized: "Fires \(n) times")) }
        if preset.joysticks.count > 1 { details.append(String(localized: "On \(groupDeviceName(match.joystickIndex))")) }
        // A macro, hold or double tap row with no plain output still does
        // something: its first such line heads it, not "Nothing chosen yet".
        var headline = !note.isEmpty ? note : outputs
        if headline.isEmpty {
            let macroLine = b.macroSteps.flatMap { $0.isEmpty ? nil : ($0.count == 1 ? String(localized: "Runs a macro of 1 step") : String(localized: "Runs a macro of \($0.count) steps")) }
            let candidates = [macroLine] + [b.holdOutputs, b.doubleTapOutputs, b.tripleTapOutputs].enumerated().map { i, list -> String? in
                guard let list, !list.isEmpty else { return nil }
                let names = OutputAction.names(list).joined(separator: " + ")
                return [String(localized: "Held: \(names)"), String(localized: "Double tap: \(names)"), String(localized: "Triple tap: \(names)")][i]
            }
            if let first = candidates.compactMap({ $0 }).first {
                headline = first
                details.removeAll { $0 == first }
            } else {
                headline = String(localized: "Nothing chosen yet")
            }
        }
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
            Image(systemName: "chevron.forward")
                .font(.caption)
                .foregroundStyle(.hint)
                .padding(.top, 2)
                .accessibilityHidden(true)
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
        guard index < preset.joysticks.count else { return String(localized: "Input Device \(index)") }
        if let name = preset.joysticks[index].shownCustomName, !name.isEmpty { return name }
        if let mac = preset.joysticks[index].macInputName { return mac }
        let slots = controllerService.effectiveSlots(for: preset.joysticks)
        return slots[index].flatMap { controllerService.controllerDetails[$0]?.name } ?? String(localized: "Input Device \(index)")
    }

    /// Closes the popover first and opens the editor a beat later, so the
    /// popover's close and the editor's slide do not land in one frame.
    func jump(_ target: EditorJumpTarget) {
        openInspectorLabel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { onJump?(target) }
    }

    /// Zones are drawn in the editor, in this group's Zones section, on the
    /// part that was clicked.
    private func openRegionEditor(_ editor: VisualizerRegionEditor) {
        let part: ZonePart
        switch editor {
        case .touchpadSetup: part = .touchpad
        case .screenRegions: part = .screen
        case .stickZones(let key): part = key.map(ZonePart.init(regionKey:)) ?? .stick(0)
        }
        jump(EditorJumpTarget(joystickIndex: slot, inputSerialized: "", action: .showZones(part)))
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
        // Pads read directly or through a helper (the Steam Controllers)
        // keep their own zero and are re-zeroed the same way.
        let directSlots = controllerService.rawHIDGamepadSlots.filter {
            $0.value.profile?.layout == .steamController2026 || RawHIDGamepadService.isSwitch2Layout($0.value.profile?.layout)
        }.map(\.key)
            + (controllerService.steamControllerSlot.map { [$0] } ?? [])
        for slot in Array(controllerService.connectedControllers.indices) + directSlots.sorted() {
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
                ? String(localized: "No motion-capable controller connected")
                : count == 0
                    ? String(localized: "Moving, hold it still and try again")
                    : count == 1 ? String(localized: "Zeroed on 1 controller") : String(localized: "Zeroed on \(count) controllers")
        }
        if let said = gyroResetFeedback { AccessibilityNotification.Announcement(said).post() }
        // A failure stays longer: it is the one that needs reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + (count == 0 ? 5 : 1.5)) {
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
        // Locale digits and percent sign, as the rest of the app writes them.
        func pct(_ v: Float) -> String { (Double(v)).formatted(.percent.precision(.fractionLength(0))) }
        var help: String
        if oneWay {
            mark.thresholds = Array(Set(inner[.right] ?? [])).sorted()
            help = mark.thresholds.count > 1
                ? String(localized: "Rows start at \(mark.thresholds.map(pct).joined(separator: ", ")): red up to the first, an orange line at each")
                : String(localized: "Deadzone \(pct(mark.right))")
            if let o = outer[.right] { help += String(localized: ", full push at \(pct(o))") }
        } else {
            // Ways with the same deadzone named together.
            let names: [DeadzoneWay: String] = [.right: String(localized: "right"), .left: String(localized: "left"), .down: String(localized: "down"), .up: String(localized: "up")]
            let read = DeadzoneWay.allCases.filter { first[$0] != nil }
            let byValue = Dictionary(grouping: read) { first[$0] ?? 0 }
            if byValue.count == 1, let v = byValue.keys.first {
                help = String(localized: "Deadzone \(pct(v))")
            } else {
                let perWay = byValue.keys.sorted().map { v in
                    // One phrase translators can reorder.
                    String(localized: "deadzone.percentWays", defaultValue: "\(pct(v)) \(LocalizedList.and((byValue[v] ?? []).map { names[$0] ?? "" }))",
                           comment: "A deadzone percent, then the directions it applies to")
                }.joined(separator: ", ")
                help = String(localized: "Deadzone \(perWay)")
            }
            let moves = Set(ways.values.flatMap { [$0.positive] + [$0.negative].compactMap { $0 } })
            let unreadNames = DeadzoneWay.allCases.filter { first[$0] == nil && moves.contains($0) }.map { names[$0] ?? "" }
            if !unreadNames.isEmpty { help += String(localized: "; no row reads \(LocalizedList.or(unreadNames))") }
            // A later row the same way: the ring is the first one.
            let later = DeadzoneWay.allCases.compactMap { w -> String? in
                let starts = Array(Set(inner[w] ?? [])).sorted()
                return starts.count > 1 ? names[w].map {
                    String(localized: "deadzone.wayStarts", defaultValue: "\($0) \(starts.dropFirst().map(pct).joined(separator: ", "))",
                           comment: "A direction, then the deadzones later rows start at that way")
                } : nil
            }
            if !later.isEmpty { help += String(localized: "; the ring is the first row each way, others start at \(later.joined(separator: "; "))") }
            let outers = DeadzoneWay.allCases.compactMap { outer[$0] }
            if let o = outers.min() { help += String(localized: "; full push at \(pct(o))") }
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
                    MotionDeadzoneMeter(channel: ch, value: st.motion[ch] ?? 0, rows: mine,
                                        neutral: MappingEngine.current?.angleNeutral(readSlot: deviceSlot, channel: ch))
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
