import Foundation
import CoreGraphics

/// Checks a layout for the mistakes that make a drawing wrong: a control off
/// its face, two controls on top of each other, a trackpad with no surface,
/// or an input placed twice.
enum LayoutValidation {
    struct Issue: CustomStringConvertible {
        let model: ControllerModelID
        let message: String
        var description: String { "\(model): \(message)" }
    }

    static func validate(_ layout: ControllerLayout) -> [Issue] {
        guard layout.isComplete else { return [] }
        var issues: [Issue] = []
        func add(_ m: String) { issues.append(Issue(model: layout.id, message: m)) }

        for c in layout.controls {
            if !(0...1).contains(c.center.x) || !(0...1).contains(c.center.y) {
                add("\(c.id) center \(c.center) is off its face")
            }
            if c.size <= 0 || c.size > 1 { add("\(c.id) size \(c.size) is out of range") }
        }

        // Overlap: on one face, two controls (neither an overlay of the
        // other) whose boxes overlap by more than 15 percent of the smaller.
        for face in [LayoutFace.front, .top, .back] {
            let list = layout.controls.filter { $0.face == face }
            let faceHeight: CGFloat = face == .front ? 1 / layout.aspect : (face == .top ? layout.topStrip : layout.backStrip)
            func box(_ c: PlacedControl) -> CGRect {
                let w = c.size, h = (c.height ?? c.size) / max(faceHeight, 0.01)
                return CGRect(x: c.center.x - w / 2, y: c.center.y - h / 2, width: w, height: h)
            }
            for i in list.indices {
                for j in list.indices where j > i {
                    let a = list[i], b = list[j]
                    if a.overlayOf == b.id || b.overlayOf == a.id { continue }
                    // Never drawn together: different variants.
                    if let va = a.variants, let vb = b.variants, va.isDisjoint(with: vb) { continue }
                    let ra = box(a), rb = box(b)
                    // A hub control inside a wheel's rim sits on it.
                    if (a.kind == .wheel && ra.contains(rb)) || (b.kind == .wheel && rb.contains(ra)) { continue }
                    let inter = ra.intersection(rb)
                    guard !inter.isNull else { continue }
                    let smaller = min(ra.width * ra.height, rb.width * rb.height)
                    if smaller > 0, inter.width * inter.height / smaller > 0.15 {
                        add("\(a.id) and \(b.id) overlap on the \(face.rawValue)")
                    }
                }
            }
        }

        for s in layout.touchSurfaces {
            guard let c = layout.control(s.controlID) else { add("surface \(s.surface) names missing control \(s.controlID)"); continue }
            if c.kind != .trackpad { add("surface \(s.surface) control \(c.id) is not a trackpad") }
        }
        for c in layout.controls where c.kind == .trackpad && layout.surface(forControl: c.id) == nil {
            add("trackpad \(c.id) has no touch surface")
        }

        // Two controls are drawn together unless their variant lists are
        // disjoint (no list means every variant).
        func shareVariant(_ a: PlacedControl?, _ b: PlacedControl) -> Bool {
            guard let a, let va = a.variants, let vb = b.variants else { return true }
            return !va.isDisjoint(with: vb)
        }
        // An input placed twice (outside a declared overlay).
        var seen: [Int: String] = [:]
        for c in layout.controls where c.readable != .notReported("") {
            if case .notReported = c.readable { continue }
            for b in c.inputs.allButtons {
                if let other = seen[b], layout.control(other)?.overlayOf != c.id, c.overlayOf != other,
                   shareVariant(layout.control(other), c) {
                    add("btn \(b) is on both \(other) and \(c.id)")
                }
                seen[b] = c.id
            }
        }
        return issues
    }

    /// Every complete layout's issues.
    static func validateAll() -> [Issue] { ControllerLayoutCatalog.all.flatMap(validate) }
}
