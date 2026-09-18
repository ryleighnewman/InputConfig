import SwiftUI

/// Stylized top-down mouse diagram for the Live Visualizer. Shows
/// left / right / middle buttons as separate regions, a scroll wheel
/// in the middle with up/down arrows, and a motion indicator under
/// the body. Each region lights green when its corresponding mouse
/// event arrives, matches the keyboard-mode treatment.
///
/// Everything here is driven by `ExternalInputDeviceService.rawActiveInputs`
/// and the service's live Force Touch reading: buttons stay lit while
/// held, scroll and motion flash for a moment after they happen.
struct MouseDiagramView: View {
    /// Mouse buttons currently held, numbered the way macOS reports them:
    /// 0 main, 1 secondary, 2 middle, then the side buttons.
    let pressedButtons: Set<Int>
    /// Momentary activity: "scrollUp", "scrollDown", "scrollLeft",
    /// "scrollRight", "move", "pressure", "deepPress".
    let activeKinds: Set<String>
    /// Kinds the slot has a binding for ("btn0", "scrollUp", "move",
    /// "pressure", "deepPress"). Drives the "dim until bound" treatment.
    let boundKinds: Set<String>
    /// Live Force Touch reading from the Mac trackpad, 0 to 1, and its
    /// click stage: 0 not clicked, 1 clicked, 2 force click.
    var pressure: Float = 0
    var pressureStage: Int = 0
    /// Finger scrolling on a trackpad or Magic Mouse: none, fingers on, or
    /// coasting on momentum after they lift.
    var scrollGesture: ExternalInputDeviceService.ScrollGesture = .none

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 6) {
                mouseBody
                Text("Mouse").font(.caption2).foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                trackpadBody
                Text("Trackpad").font(.caption2).foregroundStyle(.tertiary)
                scrollGestureChip
                forceTouchGauge
            }
            legend
        }
    }

    /// The built-in trackpad. macOS reports no finger positions for it, so
    /// the pad shows what can be known: a click (the right half for a
    /// two-finger click), how hard it is pressed, a force click, and two
    /// finger dots with the direction while a scroll gesture is on.
    private var trackpadBody: some View {
        let clicked = pressedButtons.contains(0)
        let rightClicked = pressedButtons.contains(1)
        let forced = pressureStage >= 2
        let scrolling = scrollGesture != .none
        let dir: String? = activeKinds.contains("scrollUp") ? "arrow.up"
                         : activeKinds.contains("scrollDown") ? "arrow.down"
                         : activeKinds.contains("scrollLeft") ? "arrow.left"
                         : activeKinds.contains("scrollRight") ? "arrow.right" : nil
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(forced ? Color.green.opacity(0.45)
                      : clicked ? Color.green.opacity(0.3)
                      : Color.secondary.opacity(0.06 + Double(min(1, pressure)) * 0.3))
            RoundedRectangle(cornerRadius: 10)
                .stroke(clicked || forced ? Color.green : Color.secondary.opacity(0.5), lineWidth: 1)
            if rightClicked {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.35))
                    .frame(width: 55)
                    .offset(x: 27)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if scrolling {
                HStack(spacing: 10) {
                    Circle().fill(Color.green.opacity(scrollGesture == .fingers ? 0.9 : 0.4)).frame(width: 12, height: 12)
                    Circle().fill(Color.green.opacity(scrollGesture == .fingers ? 0.9 : 0.4)).frame(width: 12, height: 12)
                }
                .offset(y: -8)
                if let dir {
                    Image(systemName: dir)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.green)
                        .offset(y: 16)
                }
            }
            if activeKinds.contains("doubleClick") {
                Circle().stroke(Color.green, lineWidth: 2).frame(width: 30, height: 30)
            }
        }
        .frame(width: 110, height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trackpad")
        .accessibilityValue(forced ? "force click" : clicked ? "clicked" : rightClicked ? "two-finger click" : scrolling ? "scrolling" : "idle")
    }

    /// The stylized mouse silhouette. Body is a vertical rounded
    /// rectangle; the left and right halves are the buttons; the
    /// middle hosts the scroll wheel; two side buttons sit on the left
    /// edge; a motion ring at the bottom.
    private var mouseBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: 90, height: 140)

            Path { p in
                p.move(to: CGPoint(x: 45, y: 4))
                p.addLine(to: CGPoint(x: 45, y: 65))
            }
            .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
            .frame(width: 90, height: 140)

            buttonRegion(active: pressedButtons.contains(0), bound: boundKinds.contains("btn0"))
                .frame(width: 44, height: 60)
                .clipShape(RoundedCorner(radius: 22, corners: [.topLeft]))
                .position(x: 23, y: 32)

            buttonRegion(active: pressedButtons.contains(1), bound: boundKinds.contains("btn1"))
                .frame(width: 44, height: 60)
                .clipShape(RoundedCorner(radius: 22, corners: [.topRight]))
                .position(x: 67, y: 32)

            // Scroll wheel with all four directions.
            VStack(spacing: 2) {
                arrow("chevron.up", on: activeKinds.contains("scrollUp"), bound: boundKinds.contains("scrollUp"))
                HStack(spacing: 2) {
                    arrow("chevron.left", on: activeKinds.contains("scrollLeft"), bound: boundKinds.contains("scrollLeft"))
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pressedButtons.contains(2)
                                  ? Color.green.opacity(0.7)
                                  : Color.secondary.opacity(boundKinds.contains("btn2") ? 0.3 : 0.12))
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(pressedButtons.contains(2) ? Color.green : Color.secondary.opacity(0.4),
                                    lineWidth: 0.5)
                    }
                    .frame(width: 8, height: 16)
                    arrow("chevron.right", on: activeKinds.contains("scrollRight"), bound: boundKinds.contains("scrollRight"))
                }
                arrow("chevron.down", on: activeKinds.contains("scrollDown"), bound: boundKinds.contains("scrollDown"))
            }
            .position(x: 45, y: 28)

            // Side buttons 4 and 5 on the left edge.
            ForEach([3, 4], id: \.self) { b in
                RoundedRectangle(cornerRadius: 2)
                    .fill(pressedButtons.contains(b)
                          ? Color.green.opacity(0.8)
                          : Color.secondary.opacity(boundKinds.contains("btn\(b)") ? 0.35 : 0.12))
                    .frame(width: 5, height: 16)
                    .position(x: 3, y: b == 3 ? 78 : 98)
            }

            // Motion ring at the bottom, lit on any move.
            Circle()
                .stroke(activeKinds.contains("move")
                        ? Color.green
                        : Color.secondary.opacity(boundKinds.contains("move") ? 0.4 : 0.15),
                        lineWidth: 1.5)
                .frame(width: 32, height: 32)
                .position(x: 45, y: 105)
        }
        .frame(width: 90, height: 140)
    }

    private func arrow(_ name: String, on: Bool, bound: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(on ? Color.green : Color.secondary.opacity(bound ? 0.7 : 0.3))
            .frame(width: 10, height: 10)
    }

    private func buttonRegion(active: Bool, bound: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.green.opacity(0.6)
                          : Color.secondary.opacity(bound ? 0.18 : 0.05))
    }

    /// What a finger scroll is doing: lit while fingers are on, dimmer while
    /// the scroll coasts on momentum, quiet otherwise.
    private var scrollGestureChip: some View {
        let text = scrollGesture == .fingers ? "Scrolling, fingers on"
                 : (scrollGesture == .momentum ? "Scrolling, momentum" : "No scroll gesture")
        let on = scrollGesture != .none
        return Text(text)
            .font(.caption2)
            .foregroundStyle(on ? Color.green : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.green.opacity(scrollGesture == .fingers ? 0.22 : 0.12)
                                          : Color.secondary.opacity(0.08)))
            .accessibilityLabel("Scroll gesture")
            .accessibilityValue(text)
    }

    /// Force Touch: how hard the trackpad is being pressed and whether that
    /// is a click or a force click. Reads only while this window is in
    /// front, since macOS gives trackpad force to the front app alone.
    private var forceTouchGauge: some View {
        let stageText = pressureStage >= 2 ? "Force click" : (pressureStage == 1 ? "Click" : "Force Touch")
        let lit = pressureStage >= 2 || activeKinds.contains("deepPress")
        return VStack(spacing: 3) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 90, height: 6)
                Capsule().fill(lit ? Color.green : Color.accentColor)
                    .frame(width: max(0, CGFloat(min(1, pressure))) * 90, height: 6)
            }
            Text(stageText)
                .font(.caption2)
                .foregroundStyle(lit ? Color.green : (pressureStage == 1 ? Color.primary : Color.secondary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Force Touch")
        .accessibilityValue(String(format: "%.0f percent, %@", pressure * 100, stageText))
    }

    /// Legend next to the silhouette. Each row dims when the slot's
    /// bindings do not use that input.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendItem(symbol: "1", label: "Left click", bound: boundKinds.contains("btn0"), on: pressedButtons.contains(0))
            legendItem(symbol: "2", label: "Right click", bound: boundKinds.contains("btn1"), on: pressedButtons.contains(1))
            legendItem(symbol: "3", label: "Middle click", bound: boundKinds.contains("btn2"), on: pressedButtons.contains(2))
            legendItem(symbol: "4", label: "Side button 4", bound: boundKinds.contains("btn3"), on: pressedButtons.contains(3))
            legendItem(symbol: "5", label: "Side button 5", bound: boundKinds.contains("btn4"), on: pressedButtons.contains(4))
            legendItem(symbol: "▲▼", label: "Scroll up / down",
                       bound: boundKinds.contains("scrollUp") || boundKinds.contains("scrollDown"),
                       on: activeKinds.contains("scrollUp") || activeKinds.contains("scrollDown"))
            legendItem(symbol: "◀▶", label: "Scroll left / right",
                       bound: boundKinds.contains("scrollLeft") || boundKinds.contains("scrollRight"),
                       on: activeKinds.contains("scrollLeft") || activeKinds.contains("scrollRight"))
            legendItem(symbol: "↔︎", label: "Motion", bound: boundKinds.contains("move"), on: activeKinds.contains("move"))
            legendItem(symbol: "2×", label: "Double click", bound: boundKinds.contains("doubleClick"), on: activeKinds.contains("doubleClick"))
            legendItem(symbol: "≋", label: "Scroll gesture", bound: boundKinds.contains("scrollGesture"), on: scrollGesture != .none)
            legendItem(symbol: "◉", label: "Force click",
                       bound: boundKinds.contains("deepPress") || boundKinds.contains("pressure"),
                       on: pressureStage >= 2)
        }
        .font(.caption2)
    }

    private func legendItem(symbol: String, label: String, bound: Bool, on: Bool) -> some View {
        HStack(spacing: 6) {
            Text(symbol)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(on ? Color.green : Color.secondary)
            Text(label)
                .foregroundStyle(on ? Color.green : (bound ? Color.primary : Color.secondary))
        }
    }
}

/// Helper to clip individual corners of a Rectangle.
private struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCornerLike

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tlRadius = corners.contains(.topLeft) ? radius : 0
        let trRadius = corners.contains(.topRight) ? radius : 0
        let blRadius = corners.contains(.bottomLeft) ? radius : 0
        let brRadius = corners.contains(.bottomRight) ? radius : 0
        p.move(to: CGPoint(x: rect.minX + tlRadius, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - trRadius, y: rect.minY))
        if trRadius > 0 {
            p.addArc(center: CGPoint(x: rect.maxX - trRadius, y: rect.minY + trRadius),
                     radius: trRadius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - brRadius))
        if brRadius > 0 {
            p.addArc(center: CGPoint(x: rect.maxX - brRadius, y: rect.maxY - brRadius),
                     radius: brRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.minX + blRadius, y: rect.maxY))
        if blRadius > 0 {
            p.addArc(center: CGPoint(x: rect.minX + blRadius, y: rect.maxY - blRadius),
                     radius: blRadius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tlRadius))
        if tlRadius > 0 {
            p.addArc(center: CGPoint(x: rect.minX + tlRadius, y: rect.minY + tlRadius),
                     radius: tlRadius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        p.closeSubpath()
        return p
    }
}

private struct UIRectCornerLike: OptionSet {
    let rawValue: Int
    static let topLeft     = UIRectCornerLike(rawValue: 1 << 0)
    static let topRight    = UIRectCornerLike(rawValue: 1 << 1)
    static let bottomLeft  = UIRectCornerLike(rawValue: 1 << 2)
    static let bottomRight = UIRectCornerLike(rawValue: 1 << 3)
}
