import Foundation
import CoreGraphics

/// One step of an outline, in a face's 0...1 coordinates.
enum PathOp: Sendable, Equatable {
    case move(CGFloat, CGFloat)
    case line(CGFloat, CGFloat)
    /// To (x, y) through the control point (cx, cy).
    case quad(CGFloat, CGFloat, cx: CGFloat, cy: CGFloat)
    /// To (x, y) through the control points (c1x, c1y) and (c2x, c2y).
    case curve(CGFloat, CGFloat, c1x: CGFloat, c1y: CGFloat, c2x: CGFloat, c2y: CGFloat)
    case close
}

/// A controller's outline on each face it draws.
struct Silhouette: Sendable {
    var front: [PathOp]
    var top: [PathOp]? = nil
    var back: [PathOp]? = nil

    func ops(for face: LayoutFace) -> [PathOp]? {
        switch face {
        case .front: return front
        case .top: return top
        case .back: return back
        }
    }

    /// The outline as a CGPath in `rect`.
    func path(for face: LayoutFace, in rect: CGRect) -> CGPath? {
        guard let ops = ops(for: face) else { return nil }
        return Self.path(ops, in: rect)
    }

    static func path(_ ops: [PathOp], in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        for op in ops {
            switch op {
            case .move(let x, let y): p.move(to: pt(x, y))
            case .line(let x, let y): p.addLine(to: pt(x, y))
            case .quad(let x, let y, let cx, let cy): p.addQuadCurve(to: pt(x, y), control: pt(cx, cy))
            case .curve(let x, let y, let c1x, let c1y, let c2x, let c2y):
                p.addCurve(to: pt(x, y), control1: pt(c1x, c1y), control2: pt(c2x, c2y))
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    // MARK: - Symmetry

    /// A closed outline from its left half: `leftHalf` starts on the center
    /// line (x 0.5) at the top, runs down the player's left side, and ends
    /// on the center line at the bottom. The right half is its mirror,
    /// traced back up.
    static func symmetric(_ leftHalf: [PathOp]) -> [PathOp] {
        enum Seg { case line(CGPoint, CGPoint); case quad(CGPoint, CGPoint, CGPoint); case curve(CGPoint, CGPoint, CGPoint, CGPoint) }
        var segs: [Seg] = []
        var cur = CGPoint.zero
        var start = CGPoint.zero
        for op in leftHalf {
            switch op {
            case .move(let x, let y): cur = CGPoint(x: x, y: y); start = cur
            case .line(let x, let y): let e = CGPoint(x: x, y: y); segs.append(.line(cur, e)); cur = e
            case .quad(let x, let y, let cx, let cy):
                let e = CGPoint(x: x, y: y); segs.append(.quad(cur, CGPoint(x: cx, y: cy), e)); cur = e
            case .curve(let x, let y, let c1x, let c1y, let c2x, let c2y):
                let e = CGPoint(x: x, y: y)
                segs.append(.curve(cur, CGPoint(x: c1x, y: c1y), CGPoint(x: c2x, y: c2y), e)); cur = e
            case .close: break
            }
        }
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.x, y: p.y) }
        var out: [PathOp] = [.move(start.x, start.y)] + leftHalf.filter {
            if case .move = $0 { return false }
            if case .close = $0 { return false }
            return true
        }
        for seg in segs.reversed() {
            switch seg {
            case .line(let a, _): let e = m(a); out.append(.line(e.x, e.y))
            case .quad(let a, let c, _): let e = m(a), cc = m(c); out.append(.quad(e.x, e.y, cx: cc.x, cy: cc.y))
            case .curve(let a, let c1, let c2, _):
                let e = m(a), n1 = m(c2), n2 = m(c1)
                out.append(.curve(e.x, e.y, c1x: n1.x, c1y: n1.y, c2x: n2.x, c2y: n2.y))
            }
        }
        out.append(.close)
        return out
    }

    // MARK: - Ready-made bodies

    /// A rounded rectangle filling the face.
    static func roundedRectOps(corner r: CGFloat, inset i: CGFloat = 0.01) -> [PathOp] {
        let a = i, b = 1 - i
        return [.move(a + r, a), .line(b - r, a), .quad(b, a + r, cx: b, cy: a), .line(b, b - r),
                .quad(b - r, b, cx: b, cy: b), .line(a + r, b), .quad(a, b - r, cx: a, cy: b),
                .line(a, a + r), .quad(a + r, a, cx: a, cy: a), .close]
    }

    /// An ellipse filling the face.
    static func ellipseOps(inset i: CGFloat = 0.01) -> [PathOp] {
        let k: CGFloat = 0.5523 * (0.5 - i)
        return [.move(0.5, i),
                .curve(1 - i, 0.5, c1x: 0.5 + k, c1y: i, c2x: 1 - i, c2y: 0.5 - k),
                .curve(0.5, 1 - i, c1x: 1 - i, c1y: 0.5 + k, c2x: 0.5 + k, c2y: 1 - i),
                .curve(i, 0.5, c1x: 0.5 - k, c1y: 1 - i, c2x: i, c2y: 0.5 + k),
                .curve(0.5, i, c1x: i, c1y: 0.5 - k, c2x: 0.5 - k, c2y: i), .close]
    }

    /// The two-grip gamepad body most controllers share.
    /// - gripLength: how far the grips hang below the body (0...0.5).
    /// - waist: the y of the arch between the grips (0.55 tight, 0.8 shallow).
    /// - shoulder: how square the top corners are (0 round, 1 square).
    /// - gripWidth: each grip's width at the bottom (0.15...0.3).
    /// - flare: how far the sides bulge past the shoulders.
    static func gamepad(gripLength: CGFloat = 0.32, waist: CGFloat = 0.66, shoulder: CGFloat = 0.5,
                        gripWidth: CGFloat = 0.22, flare: CGFloat = 0.02, topDip: CGFloat = 0.02) -> Silhouette {
        let bodyBottom = 1 - gripLength
        let sx = 0.1 + 0.06 * (1 - shoulder)           // shoulder corner x
        let gripOuter = 0.03 + flare
        let gripInner = gripOuter + gripWidth
        let left: [PathOp] = [
            .move(0.5, 0.02 + topDip),
            .curve(sx + 0.06, 0.03, c1x: 0.38, c1y: 0.02 + topDip, c2x: 0.26, c2y: 0.02),
            .curve(0.015, bodyBottom * 0.5, c1x: 0.02 + 0.06 * shoulder, c1y: 0.04, c2x: 0.0, c2y: bodyBottom * 0.22),
            .curve(gripOuter + 0.02, 0.96, c1x: 0.03, c1y: bodyBottom * 0.85, c2x: gripOuter - 0.01, c2y: 0.86),
            .curve(gripInner, 0.95, c1x: gripOuter + 0.06, c1y: 1.0, c2x: gripInner - 0.03, c2y: 1.0),
            .curve(0.36, waist + 0.04, c1x: gripInner + 0.04, c1y: 0.88, c2x: 0.3, c2y: waist + 0.06),
            .curve(0.5, waist, c1x: 0.41, c1y: waist + 0.02, c2x: 0.46, c2y: waist),
        ]
        return Silhouette(front: symmetric(left),
                          top: roundedRectOps(corner: 0.18, inset: 0.04),
                          back: roundedRectOps(corner: 0.2, inset: 0.04))
    }

    /// A box: an arcade stick, a leverless board, a Stream Deck.
    static func box(corner: CGFloat = 0.06) -> Silhouette {
        Silhouette(front: roundedRectOps(corner: corner), top: roundedRectOps(corner: 0.1, inset: 0.04))
    }

    /// A flat pad with rounded ends (SNES-style, NES-style).
    static func bar(roundness: CGFloat = 0.5) -> Silhouette {
        let r = 0.1 + 0.38 * roundness
        return Silhouette(front: roundedRectOps(corner: r), top: roundedRectOps(corner: 0.18, inset: 0.04))
    }

    /// A racing wheel seen from the driver's seat.
    static func wheel() -> Silhouette {
        Silhouette(front: ellipseOps(inset: 0.02))
    }

    /// A flight stick from above: the base plate and the grip.
    static func flightStick() -> Silhouette {
        Silhouette(front: roundedRectOps(corner: 0.12), top: roundedRectOps(corner: 0.18, inset: 0.04))
    }
}
