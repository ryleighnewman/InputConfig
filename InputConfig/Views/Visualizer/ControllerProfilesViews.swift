import SwiftUI

/// The profiles a controller stores, in the Live Visualizer, above its
/// drawing: a chip that names the active one and opens the list.
///
/// PlayStation Access controller: three profiles. Over USB-C they are read
/// from the controller, one can be made active (what the Profile button
/// does) and any can be edited beside the drawing and stored back. Over
/// Bluetooth the controller does not open its profiles to a computer, so
/// the chip shows the active profile and the Profile button switches.
struct AccessProfilesChip: View {
    typealias Service = AccessControllerPortService
    let state: Service.ProfileState
    @Binding var isPresented: Bool
    /// Makes a profile active; the second argument reports the outcome.
    let onUse: (Int, @escaping (Result<Void, Service.ProfileError>) -> Void) -> Void
    let onEdit: (Service.Profile) -> Void
    let onRefresh: () -> Void

    private var title: String {
        guard state.connected else { return String(localized: "Profiles") }
        if let p = state.profiles[state.active], !p.name.isEmpty, p.name != "Profile \(state.active)" {
            return String(localized: "Profile \(state.active): \(p.name)")
        }
        return state.active > 0 ? String(localized: "Profile \(state.active)") : String(localized: "Profiles")
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(state.overUSB ? String(localized: "The profiles stored on the controller: switch, or edit one")
              : String(localized: "The profile the controller has active"))
        .accessibilityLabel("Controller profiles")
        .accessibilityValue(title)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            AccessProfilesPopover(state: state, onUse: onUse, onEdit: onEdit, onRefresh: onRefresh)
        }
    }
}

struct AccessProfilesPopover: View {
    typealias Service = AccessControllerPortService
    let state: Service.ProfileState
    let onUse: (Int, @escaping (Result<Void, Service.ProfileError>) -> Void) -> Void
    let onEdit: (Service.Profile) -> Void
    let onRefresh: () -> Void
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stored profiles")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(1...3, id: \.self) { number in
                row(number)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.overUSB {
                Button {
                    onRefresh()
                    message = String(localized: "Reading the controller's profiles again.")
                } label: {
                    Label("Read again", systemImage: "arrow.clockwise")
                        .font(.callout)
                }
                .buttonStyle(.solidSecondaryCompact)
                .help("Read the three profiles from the controller again")
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var subtitle: String {
        if !state.connected { return String(localized: "No Access controller is connected.") }
        if state.overUSB {
            return state.profiles.isEmpty
                ? String(localized: "Connected by USB-C. The profiles have not been read yet.")
                : String(localized: "Read from the controller over USB-C. Use makes a profile active, the same as the Profile button; Edit opens it beside the drawing.")
        }
        return String(localized: "Over Bluetooth the controller keeps its profiles to itself: it shows which one is active, and its Profile button switches. Connect by USB-C to view and edit them.")
    }

    @ViewBuilder
    private func row(_ number: Int) -> some View {
        let profile = state.profiles[number]
        let active = state.active == number
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: active ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .font(.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile?.shownName ?? String(localized: "Profile \(number)"))
                    .font(.callout.weight(active ? .semibold : .regular))
                if let profile {
                    Text(summary(profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if state.overUSB {
                Button("Use") {
                    busy = true
                    onUse(number) { result in
                        busy = false
                        switch result {
                        case .success: message = String(localized: "Profile \(number) is active.")
                        case .failure(let error): message = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.solidSecondaryCompact)
                .disabled(active || busy || state.switchingDisabled)
                .help(state.switchingDisabled ? String(localized: "Profile switching is turned off on the controller (a PS5 setting)")
                      : active ? String(localized: "This profile is active") : String(localized: "Make profile \(number) active on the controller"))
                Button("Edit") {
                    if let profile { onEdit(profile) }
                }
                .buttonStyle(.solidSecondaryCompact)
                .disabled(profile == nil || busy)
                .help("Edit this profile beside the drawing")
            } else if active {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What a profile sends, in one line: the sockets with a function and
    /// the ports that are set up.
    private func summary(_ p: Service.Profile) -> String {
        var parts: [String] = []
        let sockets = (1...10).compactMap { slot -> String? in
            guard let code = p.buttonActions[slot], code != 0, let name = Service.Profile.actionName(code) else { return nil }
            return "\(slot <= 8 ? String(slot) : slot == 9 ? String(localized: "center") : String(localized: "press")) \(name)"
        }
        if !sockets.isEmpty { parts.append(sockets.joined(separator: ", ")) }
        for port in 1...4 {
            switch p.ports[port] ?? .empty {
            case .empty: continue
            case .stick(let a): parts.append("E\(port) " + (a == 2 ? String(localized: "right stick") : String(localized: "left stick")))
            case .button(let code, _, _): parts.append("E\(port) " + (Service.Profile.actionName(code) ?? String(code)))
            }
        }
        return parts.isEmpty ? String(localized: "Nothing assigned") : parts.joined(separator: ", ")
    }
}

/// Edits one stored profile beside the controller's drawing, in the
/// PS5's own terms: Button Assignments (Assign Button, Assign Simultaneous
/// Press, Button Toggle), Controller Orientation and the expansion ports.
/// Selecting a row highlights its socket or port on the drawing, and
/// clicking a control on the drawing selects its row.
struct AccessProfileEditorPanel: View {
    typealias Service = AccessControllerPortService
    @Binding var profile: Service.Profile
    /// The drawing's control id of the row being looked at.
    @Binding var selection: String?
    let saving: Bool
    let error: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    /// The drawing's control for a button slot (1...10) and a port (1...4).
    static func controlID(slot: Int) -> String { slot <= 8 ? "socket\(slot)" : slot == 9 ? "center" : "stick" }
    static func controlID(port: Int) -> String { "e\(port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Profile \(profile.number)")
                    .font(.headline)
                Text("Stored on the controller and applied by it, on a PS5 and on the Mac. Click a row or a control on the drawing to see which is which.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Profile name", text: $profile.name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: profile.name) { _, new in
                    if new.count > 39 { profile.name = String(new.prefix(39)) }
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Button Assignments") {
                        ForEach(1...10, id: \.self) { slot in
                            buttonRow(slot)
                        }
                    }
                    section("Controller Orientation") {
                        selectable(Self.controlID(slot: 10)) {
                            VStack(alignment: .leading, spacing: 6) {
                                labeled("Stick acts as") {
                                    Picker("Stick acts as", selection: Binding(
                                        get: { stickAssignment(0) },
                                        set: { profile.ports[0] = .stick(assignment: $0) })) {
                                        Text("Left stick").tag(1)
                                        Text("Right stick").tag(2)
                                    }
                                    .labelsHidden()
                                }
                                labeled("Stick is") {
                                    Picker("Controller orientation", selection: $profile.orientation) {
                                        Text("Below the buttons").tag(0)
                                        Text("To the right").tag(1)
                                        Text("Above the buttons").tag(2)
                                        Text("To the left").tag(3)
                                    }
                                    .labelsHidden()
                                }
                                Text("Sensitivity and deadzone stay as set on the PS5.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    section("Expansion Ports") {
                        ForEach(1...4, id: \.self) { port in
                            portRow(port)
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save to Controller", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }

    // MARK: Pieces

    @ViewBuilder
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .frame(width: 118, alignment: .leading)
            content()
                .controlSize(.small)
            Spacer(minLength: 0)
        }
    }

    /// A row that selects its control on the drawing when clicked.
    @ViewBuilder
    private func selectable<Content: View>(_ id: String, @ViewBuilder content: () -> Content) -> some View {
        let on = selection == id
        content()
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onTapGesture { selection = id }
    }

    @ViewBuilder
    private func actionPicker(_ title: LocalizedStringKey, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Service.Profile.actionCodes, id: \.self) { code in
                Text(code == 0 ? String(localized: "Not Assigned") : (Service.Profile.actionName(code) ?? String(code))).tag(code)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private func buttonRow(_ slot: Int) -> some View {
        selectable(Self.controlID(slot: slot)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Service.Profile.slotName(slot))
                    .font(.callout.weight(.medium))
                labeled("Assign Button") {
                    actionPicker("Assign Button", selection: Binding(
                        get: { profile.buttonActions[slot] ?? 0 },
                        set: { profile.buttonActions[slot] = $0 == 0 ? nil : $0 }))
                }
                labeled("Simultaneous Press") {
                    actionPicker("Assign Simultaneous Press", selection: Binding(
                        get: { profile.secondaryActions[slot] ?? 0 },
                        set: { profile.secondaryActions[slot] = $0 == 0 ? nil : $0 }))
                }
                Toggle("Button Toggle", isOn: Binding(
                    get: { profile.toggles.contains(slot) },
                    set: { if $0 { profile.toggles.insert(slot) } else { profile.toggles.remove(slot) } }))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("Stays pressed after one press, like a caps lock key")
            }
        }
    }

    private func stickAssignment(_ port: Int) -> Int {
        if case .stick(let a) = profile.ports[port] ?? .empty { return a == 2 ? 2 : 1 }
        return 1
    }

    /// Nothing, a stick on either side, a button or a trigger with an action.
    private enum PortKind: Int, CaseIterable, Identifiable {
        case nothing, leftStick, rightStick, button, analog
        var id: Int { rawValue }
        var name: String {
            switch self {
            case .nothing: return String(localized: "Not Assigned")
            case .leftStick: return String(localized: "Stick, as the left stick")
            case .rightStick: return String(localized: "Stick, as the right stick")
            case .button: return String(localized: "Button or switch")
            case .analog: return String(localized: "Trigger or pedal")
            }
        }
    }

    private func kind(_ port: Int) -> PortKind {
        switch profile.ports[port] ?? .empty {
        case .empty: return .nothing
        case .stick(let a): return a == 2 ? .rightStick : .leftStick
        case .button(_, _, let analog): return analog ? .analog : .button
        }
    }

    private func portButton(_ port: Int) -> (code: Int, secondary: Int, analog: Bool) {
        if case .button(let c, let s, let a) = profile.ports[port] ?? .empty { return (c, s, a) }
        return (0, 0, false)
    }

    @ViewBuilder
    private func portRow(_ port: Int) -> some View {
        let current = kind(port)
        selectable(Self.controlID(port: port)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("E\(port)")
                    .font(.callout.weight(.medium))
                labeled("Device") {
                    Picker("E\(port)", selection: Binding(
                        get: { current },
                        set: { new in
                            let b = portButton(port)
                            switch new {
                            case .nothing: profile.ports[port] = .empty
                            case .leftStick: profile.ports[port] = .stick(assignment: 1)
                            case .rightStick: profile.ports[port] = .stick(assignment: 2)
                            case .button: profile.ports[port] = .button(code: b.code, secondary: b.secondary, analog: false)
                            case .analog: profile.ports[port] = .button(code: b.code, secondary: b.secondary, analog: true)
                            }
                        })) {
                        ForEach(PortKind.allCases) { k in Text(k.name).tag(k) }
                    }
                    .labelsHidden()
                }
                if current == .button || current == .analog {
                    labeled("Assign Button") {
                        actionPicker("Assign Button", selection: Binding(
                            get: { portButton(port).code },
                            set: { let b = portButton(port); profile.ports[port] = .button(code: $0, secondary: b.secondary, analog: b.analog) }))
                    }
                    labeled("Simultaneous Press") {
                        actionPicker("Assign Simultaneous Press", selection: Binding(
                            get: { portButton(port).secondary },
                            set: { let b = portButton(port); profile.ports[port] = .button(code: b.code, secondary: $0, analog: b.analog) }))
                    }
                    Toggle("Button Toggle", isOn: Binding(
                        get: { profile.toggles.contains(10 + port) },
                        set: { if $0 { profile.toggles.insert(10 + port) } else { profile.toggles.remove(10 + port) } }))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            }
        }
    }
}

/// The DualSense Edge's four stored profiles, read over USB-C, listed
/// with what each remaps. The pad applies them itself and switches with
/// FN and a face button; editing them is Sony's PlayStation Accessories
/// app's job.
struct EdgeProfilesChip: View {
    let profiles: [DualSenseEdgeProfiles.Profile]
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.caption)
                Text(String(localized: "Profiles: \(profiles.filter(\.assigned).count) of 4"))
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("The profiles stored on the DualSense Edge")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stored profiles")
                    .font(.headline)
                Text("Read over USB-C. Hold FN and press the face button to switch on the pad; the pad applies the profile itself, so what it sends is already remapped. Edit them in Sony's PlayStation Accessories app or on a PS5.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(profiles, id: \.slot) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(p.slot.name): \(p.assigned ? (p.name.isEmpty ? String(localized: "Unnamed") : p.name) : String(localized: "Empty"))")
                            .font(.callout)
                        if p.assigned {
                            Text(p.remaps.isEmpty ? String(localized: "No buttons remapped") : p.remaps.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 340)
        }
    }
}
