import SwiftUI

/// Stylized top-down mouse diagram for the Live Visualizer. Shows
/// left / right / middle buttons as separate regions, a scroll wheel
/// in the middle with up/down arrows, and a motion indicator under
/// the body. Each region lights green when its corresponding mouse
/// event arrives, matches the keyboard-mode treatment.
///
/// What "active" means per region:
///   - left/right/middle: ExternalInputDeviceService.rawActiveInputs
///     contains the matching `ems button N + any` serialized form.
///   - scroll up/down: brief flash on every scroll event (driven by
///     the parent passing `scrollHintUp/Down`).
///   - motion: brief flash on every move event.
struct MouseDiagramView: View {
    /// Set of mouse button indices currently held (1=left, 2=right, 3=middle).
    let pressedButtons: Set<Int>
    /// Set of "kinds" the parent considers active right now. Use
    /// strings like "scrollUp", "scrollDown", "move" so the view can
    /// flash arrows without needing the full Event subscription.
    let activeKinds: Set<String>
    /// True when the slot has any binding targeting this mouse kind.
    /// Drives the "dim until bound" treatment.
    let boundKinds: Set<String>

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            mouseBody
            legend
        }
    }

    /// The stylized mouse silhouette. Body is a vertical rounded
    /// rectangle; the left and right halves are the buttons; the
    /// middle hosts the scroll wheel.
    private var mouseBody: some View {
        ZStack {
            // Outer body
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: 90, height: 140)

            // Button divider
            Path { p in
                p.move(to: CGPoint(x: 45, y: 4))
                p.addLine(to: CGPoint(x: 45, y: 65))
            }
            .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
            .frame(width: 90, height: 140)

            // Left button half
            buttonRegion(active: pressedButtons.contains(1),
                         bound: boundKinds.contains("btn1"))
                .frame(width: 44, height: 60)
                .clipShape(RoundedCorner(radius: 22, corners: [.topLeft]))
                .position(x: 23, y: 32)

            // Right button half
            buttonRegion(active: pressedButtons.contains(2),
                         bound: boundKinds.contains("btn2"))
                .frame(width: 44, height: 60)
                .clipShape(RoundedCorner(radius: 22, corners: [.topRight]))
                .position(x: 67, y: 32)

            // Scroll wheel
            VStack(spacing: 2) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(activeKinds.contains("scrollUp")
                                     ? Color.green
                                     : Color.secondary.opacity(boundKinds.contains("scrollUp") ? 0.7 : 0.3))
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(pressedButtons.contains(3)
                              ? Color.green.opacity(0.7)
                              : Color.secondary.opacity(boundKinds.contains("btn3") ? 0.3 : 0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(pressedButtons.contains(3)
                                ? Color.green
                                : Color.secondary.opacity(0.4),
                                lineWidth: 0.5)
                }
                .frame(width: 8, height: 16)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(activeKinds.contains("scrollDown")
                                     ? Color.green
                                     : Color.secondary.opacity(boundKinds.contains("scrollDown") ? 0.7 : 0.3))
            }
            .position(x: 45, y: 28)

            // Motion ring at bottom (lights up on any move)
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

    private func buttonRegion(active: Bool, bound: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.green.opacity(0.6)
                          : Color.secondary.opacity(bound ? 0.18 : 0.05))
    }

    /// Compact legend next to the silhouette so the user knows which
    /// region maps to which input. Each row dims if the slot's
    /// bindings don't target that kind.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendItem(symbol: "1", label: "Left button", bound: boundKinds.contains("btn1"))
            legendItem(symbol: "2", label: "Right button", bound: boundKinds.contains("btn2"))
            legendItem(symbol: "3", label: "Middle / wheel", bound: boundKinds.contains("btn3"))
            legendItem(symbol: "▲", label: "Scroll up", bound: boundKinds.contains("scrollUp"))
            legendItem(symbol: "▼", label: "Scroll down", bound: boundKinds.contains("scrollDown"))
            legendItem(symbol: "↔︎", label: "Motion", bound: boundKinds.contains("move"))
        }
        .font(.caption2)
    }

    private func legendItem(symbol: String, label: String, bound: Bool) -> some View {
        HStack(spacing: 6) {
            Text(symbol)
                .frame(width: 14, alignment: .center)
                .foregroundStyle(.secondary)
            Text(label)
                .foregroundStyle(bound ? Color.primary : Color.secondary)
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
