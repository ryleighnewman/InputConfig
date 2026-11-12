import SwiftUI
import SceneKit
import Metal
import GameController
import UniformTypeIdentifiers

// MARK: - Controller Chip View

/// A controller read straight from its HID reports: name, slot, how it is
/// connected, and a popover with Disconnect.
/// "Experimental" beside a device read by a path not yet tested on
/// hardware: the app reads it, but its drawing and naming are generic.
struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.system(size: 9))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15))
            .foregroundStyle(.orange)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help("Read by InputConfig but not yet tested on hardware")
    }
}

struct RawHIDChipView: View {
    let slot: Int
    let gamepad: RawHIDGamepad
    let color: Color
    /// Read by a path not yet tested on hardware: marked Experimental.
    var experimental: Bool = false

    @State private var showPopover = false
    @State private var isHovering = false
    @State private var disconnectNote: String?

    var body: some View {
        Button { showPopover.toggle() } label: { chipContent }
            .buttonStyle(.plain)
            .focusRingForKeyboardUsers()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(gamepad.displayName)
            // What the chip shows under the name, so two identical pads differ.
            .accessibilityValue([String(localized: "Slot \(slot)"), String(localized: "Raw HID"),
                                 experimental ? String(localized: "Experimental") : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Opens the controller's details and Disconnect")
            .popover(isPresented: $showPopover, arrowEdge: .trailing) { popover }
            .contextMenu {
                Button("Disconnect") { disconnect(); if disconnectNote != nil { showPopover = true } }
            }
    }

    private var chipContent: some View {
        HStack(spacing: 8) {
            ControllerGlyph(height: 11)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(gamepad.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("Slot \(slot)")
                        .font(.system(size: 9))
                        .foregroundStyle(.hint)
                    Text("Raw HID")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    if experimental { ExperimentalBadge() }
                }
            }

            Spacer()

            Text(gamepad.transport)
                .font(.system(size: 9))
                .foregroundStyle(.hint)
                .padding(.trailing, 4)
            Image(systemName: "chevron.forward")
                .font(.system(size: 8))
                .foregroundStyle(.hint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .hoverFill(isHovering)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ControllerGlyph(height: 16)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gamepad.displayName)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Slot \(slot), \(gamepad.transport), read from its HID reports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            Button { disconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.solidSecondaryCompact)
            .help(gamepad.transport.localizedCaseInsensitiveContains("bluetooth")
                  ? String(localized: "Disconnects this controller from the Mac")
                  : String(localized: "Stops reading this controller until it is plugged in again or connected from InputConfig > Devices"))
            if let disconnectNote {
                Text(disconnectNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 300)
        // Cleared on the way out: the right-click Disconnect opens this to
        // show why it could not, and clearing on appear erased the reason.
        .onDisappear { disconnectNote = nil }
    }

    private func disconnect() {
        switch RawHIDGamepadService.shared.disconnect(gamepad: gamepad) {
        case .disconnected:
            disconnectNote = nil
            showPopover = false
            AccessibilityNotification.Announcement(String(localized: "\(gamepad.displayName) disconnected")).post()
        case .cannot(let why):
            disconnectNote = why
            AccessibilityNotification.Announcement(why).post()
        }
    }
}

struct ControllerChipView: View {
    /// Optional so the marketing capture pipeline can render a chip for a
    /// synthetic controller, which has no GCController behind it. Everything
    /// the chip draws comes from `info`; the controller is only consulted for
    /// its vendor name.
    let controller: GCController?
    let index: Int
    let color: Color
    let info: ControllerInfo?
    let onSetLight: (Float, Float, Float) -> Void
    let onSetBrightness: (UInt8) -> Void
    let onToggleRGB: () -> Void
    let isRGBActive: Bool
    let onRefresh: () -> Void
    /// Jump to the example preset that best matches this controller.
    let onOpenExample: () -> Void
    /// Live binding to the shared RGB cycle speed (the slider in the menu).
    @Binding var rgbSpeed: Double
    /// Disconnects this controller (nil hides Disconnect).
    var onDisconnect: (() -> RawHIDGamepadService.DisconnectOutcome)? = nil
    /// Read by a path not yet tested on hardware: marked Experimental.
    var experimental: Bool = false
    /// The light's brightness now, so the picker opens on it, not on Bright.
    /// Read when the popover opens: the stored levels are not published,
    /// so a plain value went stale after the first change.
    var currentBrightness: () -> UInt8 = { 2 }
    /// What is in a PlayStation Access controller's expansion ports.
    var ports: [Int: AccessControllerPortService.PortDevice] = [:]
    /// The profile an Access controller has active, with its name when known.
    var accessProfile: (number: Int, name: String?)? = nil
    /// The profiles stored on a DualSense Edge, read over USB.
    var edgeProfiles: [DualSenseEdgeProfiles.Profile] = []

    @State private var showPopover = false
    /// Why the last Disconnect could not disconnect, shown in the popover.
    @State private var disconnectNote: String?

    // Accurate light bar colors tuned to match actual DualSense LED output
    private static let lightPresets: [(name: String, r: Float, g: Float, b: Float)] = [
        ("Red",    1.0, 0.0, 0.0),
        ("Orange", 1.0, 0.35, 0.0),
        ("Yellow", 1.0, 0.7, 0.0),
        ("Green",  0.0, 1.0, 0.0),
        ("Cyan",   0.0, 1.0, 1.0),
        ("Blue",   0.0, 0.0, 1.0),
        ("Purple", 0.5, 0.0, 1.0),
        ("Pink",   1.0, 0.0, 0.6),
        ("White",  1.0, 1.0, 1.0),
        ("Off",    0.0, 0.0, 0.0),
    ]

    @State private var customColor = Color.blue
    @State private var brightness: Double = 2
    /// The level last sent: the chip's own value is not refreshed by a
    /// brightness change, so comparing with it dropped a change back.
    @State private var appliedBrightness: UInt8 = 2
    @State private var uptimeTimer: Timer?
    @State private var uptimeText: String = ""

    @State private var isHovering = false

    var body: some View {
        // A button, so Tab and Full Keyboard Access reach it; it was a tap
        // gesture that only the pointer and VoiceOver could press.
        Button { showPopover.toggle() } label: { chipContent }
            .buttonStyle(.plain)
            .focusRingForKeyboardUsers()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller?.vendorName ?? info?.name ?? String(localized: "Controller \(index)"))
        .accessibilityValue(chipAccessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens controller light and settings")
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            controllerPopover
                .onAppear { appliedBrightness = currentBrightness(); brightness = Double(appliedBrightness) }
        }
        .contextMenu {
            if onDisconnect != nil {
                Button("Disconnect") { runDisconnect(); if disconnectNote != nil { showPopover = true } }
            }
        }
    }

    private var chipContent: some View {
        HStack(spacing: 8) {
            // Controller icon
            ControllerGlyph(height: 11)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(controller?.vendorName ?? info?.name ?? String(localized: "Controller \(index)"))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let info = info {
                    HStack(spacing: 4) {
                        Text(shortDescription(info))
                            .font(.system(size: 9))
                            .foregroundStyle(.hint)
                            .lineLimit(1)
                        if experimental { ExperimentalBadge() }
                    }
                }
            }

            Spacer()

            // Battery indicator
            if let info = info, info.hasBattery, let level = info.batteryLevel {
                batteryView(level: level, state: info.batteryState)
            }

            // Light indicator
            if info?.hasLight == true {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow.opacity(0.7))
            }

            Image(systemName: "chevron.forward")
                .font(.system(size: 8))
                .foregroundStyle(.hint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hoverFill(isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    /// Battery and light status summarized for VoiceOver so the chip reads
    /// its full state without exposing the decorative indicators separately.
    private var chipAccessibilityValue: String {
        var parts: [String] = []
        if let info = info, info.hasBattery, let level = info.batteryLevel {
            parts.append(String(localized: "Battery \(Int(level * 100)) percent"))
        }
        if info?.hasLight == true {
            parts.append(String(localized: "Has a light bar"))
        }
        return parts.joined(separator: ", ")
    }

    private func shortDescription(_ info: ControllerInfo) -> String {
        var parts: [String] = []
        // Prefer the detected brand name (DualSense, Switch Pro, etc.) when we
        // know it, since it is friendlier than productCategory (which is often
        // just "Extended Gamepad" or similar).
        if info.brand != .unknown && info.brand != .mfiGeneric {
            parts.append(info.brand.displayName)
        } else {
            parts.append(info.productCategory)
        }
        parts.append(info.buttonCount == 1 ? String(localized: "1 btn") : String(localized: "\(info.buttonCount) btns"))
        parts.append(info.shownAxisCount == 1 ? String(localized: "1 axis") : String(localized: "\(info.shownAxisCount) axes"))
        // What is in a PlayStation Access controller's expansion ports.
        for (port, device) in ports.sorted(by: { $0.key < $1.key }) {
            switch device {
            case .stick: parts.append(String(localized: "E\(port) stick"))
            case .trigger: parts.append(String(localized: "E\(port) trigger"))
            case .button: parts.append(String(localized: "E\(port) button"))
            case .invalidPlug: parts.append(String(localized: "E\(port) unrecognized"))
            }
        }
        let saved = edgeProfiles.filter(\.assigned)
        if !saved.isEmpty {
            parts.append(String(localized: "Profiles: \(saved.map { $0.name.isEmpty ? $0.slot.name : $0.name }.joined(separator: ", "))"))
        }
        if let accessProfile {
            // The PS5 names a slot "Profile N" by default: said once, not twice.
            let plain = String(localized: "Profile \(accessProfile.number)")
            if let name = accessProfile.name, !name.isEmpty, name != plain, name != "Profile \(accessProfile.number)" {
                parts.append(String(localized: "Profile \(accessProfile.number): \(name)"))
            } else {
                parts.append(plain)
            }
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func batteryView(level: Float, state: String?) -> some View {
        HStack(spacing: 2) {
            let pct = Int(level * 100)
            let icon: String = {
                if state == "Charging" { return "battery.100percent.bolt" }
                if pct >= 75 { return "battery.100percent" }
                if pct >= 50 { return "battery.75percent" }
                if pct >= 25 { return "battery.50percent" }
                return "battery.25percent"
            }()
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(pct <= 20 ? .red : .secondary)
            Text("\(pct)%")
                .font(.system(size: 9))
                .foregroundStyle(.hint)
        }
    }

    // MARK: - Popover

    private var controllerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                ControllerGlyph(height: 16)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller?.vendorName ?? info?.name ?? String(localized: "Controller \(index)"))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("Slot \(index)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !uptimeText.isEmpty {
                            Text(uptimeText)
                                .font(.caption)
                                .foregroundStyle(.hint)
                        }
                    }
                }
                Spacer()
            }

            Divider()

            // Details
            if let info = info {
                detailGrid(info)

                // Every controller - including ones we don't recognize -
                // gets a one-tap jump to the example preset that best fits
                // it (unrecognized pads fall back to the DualSense layout).
                Button {
                    showPopover = false
                    onOpenExample()
                } label: {
                    Label("Take me to an example preset", systemImage: "sparkles")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.solidSecondaryCompact)
                .padding(.top, 2)
            }

            // Light color picker
            if info?.hasLight == true {
                Divider()
                lightColorSection
            }

            // Available buttons
            if let info = info, !info.physicalButtonNames.isEmpty {
                Divider()
                DisclosureGroup {
                    Text(info.physicalButtonNames.joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.hint)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Raw Buttons (\(info.physicalButtonNames.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    onRefresh()
                    showPopover = false
                } label: {
                    Label("Refresh Controllers", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.solidSecondaryCompact)
                if onDisconnect != nil {
                    Button { runDisconnect() } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.solidSecondaryCompact)
                    .help("Disconnects this controller from the Mac")
                }
            }
            if let disconnectNote {
                Text(disconnectNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { startUptimeTimer() }
        .onDisappear { disconnectNote = nil; uptimeTimer?.invalidate(); uptimeTimer = nil }
    }

    private func runDisconnect() {
        guard let onDisconnect else { return }
        switch onDisconnect() {
        case .disconnected:
            disconnectNote = nil
            showPopover = false
            AccessibilityNotification.Announcement(String(localized: "Disconnected")).post()
        case .cannot(let why):
            disconnectNote = why
            AccessibilityNotification.Announcement(why).post()
        }
    }

    private func startUptimeTimer() {
        updateUptime()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in updateUptime() }
        }
    }

    private func updateUptime() {
        guard let info = info else { uptimeText = ""; return }
        let elapsed = Int(Date().timeIntervalSince(info.connectedAt))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        // The digits are formatted first, then put into the localized
        // string: a translated string as a printf format broke on any
        // translation that reordered or dropped a placeholder.
        let timeText = h > 0
            ? String(format: "%d:%02d:%02d", locale: .current, h, m, s)
            : String(format: "%d:%02d", locale: .current, m, s)
        uptimeText = String(localized: "\(timeText) connected")
    }

    @ViewBuilder
    private func detailGrid(_ info: ControllerInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            detailRow("Brand", info.brand.manufacturer)
            // Its own key: the catalog's "Type" is the verb, as in typing text.
            detailRow(text: String(localized: "detail.controllerType", defaultValue: "Type",
                                   comment: "Label: the kind of controller (DualSense, Xbox), a noun"),
                      info.productCategory)
            detailRow("Gamepad", info.hasExtendedGamepad ? String(localized: "Extended") : String(localized: "Basic"))
            detailRow("Buttons", "\(info.buttonCount)")
            detailRow("Axes", "\(info.shownAxisCount)")
            if info.supportsMotion {
                detailRow("Motion", String(localized: "Gyro + Accelerometer"))
            }
            if info.hasBattery {
                let level = info.batteryLevel.map { "\(Int($0 * 100))%" } ?? String(localized: "N/A")
                // Kept in English for the charging check; shown translated.
                let state: String = switch info.batteryState {
                case "Charging": String(localized: "Charging")
                case "Full": String(localized: "Full", comment: "A battery that is fully charged")
                case "Discharging": String(localized: "Discharging")
                case let other?: other == "Unknown" ? String(localized: "Unknown") : other
                case nil: String(localized: "Unknown")
                }
                detailRow("Battery", "\(level) (\(state))")
            }
            detailRow("Light Bar", info.hasLight ? String(localized: "Supported") : String(localized: "None"))
        }
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        detailRow(Text(label), value)
    }

    private func detailRow(text label: String, _ value: String) -> some View {
        detailRow(Text(verbatim: label), value)
    }

    private func detailRow(_ label: Text, _ value: String) -> some View {
        HStack {
            label
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
        }
    }

    private var lightColorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Light Bar")
                .font(.caption)
                .foregroundStyle(.secondary)

            // One grid of everything the light can be: the fixed colors,
            // a custom color (the picker itself is the swatch, and applies
            // as soon as a color is chosen), and Rainbow, which is the RGB
            // cycle. Picking any color stops the cycle.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
                ForEach(Self.lightPresets, id: \.name) { preset in
                    let swatchColor = preset.name == "Off" ? Color.gray.opacity(0.3) :
                        Color(red: Double(preset.r), green: Double(preset.g), blue: Double(preset.b))
                    LightSwatchButton(
                        name: localizedColorName(preset.name),
                        color: swatchColor,
                        action: {
                            if isRGBActive { onToggleRGB() }
                            onSetLight(preset.r, preset.g, preset.b)
                        }
                    )
                }
                // Custom: the color well is the swatch.
                VStack(spacing: 2) {
                    ColorPicker("", selection: $customColor, supportsOpacity: false)
                        .labelsHidden()
                        .scaleEffect(1.35)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: customColor.opacity(0.3), radius: 2)
                        .accessibilityLabel("Custom light bar color")
                        .voiceNames("Custom", "Custom light bar color")
                        .onChange(of: customColor) { _, value in
                            let nsColor = NSColor(value).usingColorSpace(.sRGB) ?? NSColor(value)
                            if isRGBActive { onToggleRGB() }
                            onSetLight(Float(nsColor.redComponent), Float(nsColor.greenComponent), Float(nsColor.blueComponent))
                        }
                    Text("Custom")
                        .font(.system(size: 8))
                        .foregroundStyle(.hint)
                }
                // Rainbow: the RGB cycle, as a swatch that stays lit while
                // it runs.
                Button {
                    onToggleRGB()
                } label: {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                            .overlay(
                                Circle().strokeBorder(isRGBActive ? Color.white.opacity(0.9) : Color.primary.opacity(0.12),
                                                      lineWidth: isRGBActive ? 2 : 0.5)
                            )
                            .overlay(
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .opacity(isRGBActive ? 1 : 0)
                            )
                            .frame(width: 24, height: 24)
                            .shadow(color: .white.opacity(isRGBActive ? 0.5 : 0.2), radius: isRGBActive ? 4 : 2)
                        Text(isRGBActive ? String(localized: "Stop") : String(localized: "Rainbow"))
                            .font(.system(size: 8))
                            .foregroundStyle(isRGBActive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.hint))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRGBActive ? String(localized: "Stop RGB cycle") : String(localized: "RGB cycle"))
                // The word shown under the swatch first.
                .accessibilityInputLabels([Text(isRGBActive ? String(localized: "Stop") : String(localized: "Rainbow")),
                                           Text(isRGBActive ? String(localized: "Stop RGB cycle") : String(localized: "RGB cycle"))])
            }

            // Cycle speed, only while Rainbow is running.
            if isRGBActive {
                HStack(spacing: 8) {
                    Text("Speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "tortoise")
                        .font(.system(size: 10))
                        .foregroundStyle(.hint)
                    Slider(value: $rgbSpeed, in: 0.25...6.0)
                        .accessibilityLabel("RGB cycle speed")
                        .voiceNames("Speed", "RGB cycle speed")
                        .accessibilityValue(String(format: String(localized: "%.2f times normal"), locale: .current, rgbSpeed))
                    Image(systemName: "hare")
                        .font(.system(size: 10))
                        .foregroundStyle(.hint)
                }
            }

            Divider()

            // Brightness control
            HStack(spacing: 8) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "light.min")
                    .font(.system(size: 10))
                    .foregroundStyle(.hint)
                Picker("", selection: $brightness) {
                    Text("Off").tag(0.0)
                    Text("Dim").tag(1.0)
                    Text("Bright").tag(2.0)
                }
                .pickerStyle(.segmented)
                .onChange(of: brightness) { _, newValue in
                    // Only a real change: opening the popover syncs the
                    // picker, which repainted a running preset's light.
                    let level = UInt8(newValue)
                    if level != appliedBrightness { appliedBrightness = level; onSetBrightness(level) }
                }
                .accessibilityLabel("Light bar brightness")
                Image(systemName: "light.max")
                    .font(.system(size: 10))
                    .foregroundStyle(.hint)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isRGBActive)
    }
}

// MARK: - Light Swatch Button

/// The shown name of a palette or light color. The stored names stay as they are.
func localizedColorName(_ name: String) -> String {
    switch name.lowercased() {
    case "red": return String(localized: "Red")
    case "orange": return String(localized: "Orange")
    case "yellow": return String(localized: "Yellow")
    case "green": return String(localized: "Green")
    case "cyan": return String(localized: "Cyan")
    case "blue": return String(localized: "Blue")
    case "purple": return String(localized: "Purple")
    case "pink": return String(localized: "Pink")
    case "white": return String(localized: "White")
    case "off": return String(localized: "Off")
    case "teal": return String(localized: "Teal")
    case "indigo": return String(localized: "Indigo")
    case "brown": return String(localized: "Brown")
    default: return name.capitalized
    }
}

struct LightSwatchButton: View {
    let name: String
    let color: Color
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion
    /// The system setting or the app's own Reduce motion switch.
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Circle()
                    .fill(color)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(isHovering ? 0.4 : 0.12), lineWidth: isHovering ? 1.5 : 0.5)
                    )
                    .frame(width: 24, height: 24)
                    .shadow(color: color.opacity(isHovering ? 0.6 : 0.3), radius: isHovering ? 4 : 2)
                    .scaleEffect(!reduceMotion && isHovering ? 1.15 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovering)
                Text(name)
                    .font(.system(size: 8))
                    .foregroundStyle(isHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.hint))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
