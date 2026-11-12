import Foundation
import CoreGraphics
import Observation

/// The swappable caps on a PlayStation Access controller. The box holds 19
/// button caps (8 pillow, 4 flat, 4 curve, 2 overhang, 1 wide flat) and 3
/// stick caps (standard, dome, ball); it ships with a pillow cap on every
/// socket and the dome on the stick (PlayStation Blog, Access controller
/// launch post and starter's guide). The controller never reports which
/// caps are on, so the user picks them and the drawing follows.
enum AccessButtonCap: String, Codable, CaseIterable, Sendable {
    case pillow, flat, curve, overhang, wideFlat, bare

    var name: String {
        switch self {
        case .pillow: return String(localized: "Pillow")
        case .flat: return String(localized: "Flat")
        case .curve: return String(localized: "Curve")
        case .overhang: return String(localized: "Overhang")
        case .wideFlat: return String(localized: "Wide flat")
        case .bare: return String(localized: "No cap")
        }
    }

    var detail: String {
        switch self {
        case .pillow: return String(localized: "The cap the controller ships with")
        case .flat: return String(localized: "A larger flat round cap")
        case .curve: return String(localized: "A curved cap that follows the ring")
        case .overhang: return String(localized: "Reaches in toward the center button")
        case .wideFlat: return String(localized: "One long cap over this socket and the next")
        case .bare: return String(localized: "The bare socket")
        }
    }
}

enum AccessStickCap: String, Codable, CaseIterable, Sendable {
    case dome, standard, ball

    var name: String {
        switch self {
        case .dome: return String(localized: "Dome")
        case .standard: return String(localized: "Standard")
        case .ball: return String(localized: "Ball")
        }
    }
}

/// The caps on one controller.
struct AccessCapSet: Codable, Equatable, Sendable {
    /// Socket number (1...8) to cap; a socket not listed has a pillow.
    var sockets: [Int: AccessButtonCap] = [:]
    var stick: AccessStickCap = .dome
    /// The tag clipped into a cap (the box has 23), by socket, as an
    /// Access action code; a socket not listed shows the function its
    /// profile gives it.
    var tags: [Int: Int] = [:]

    func cap(socket: Int) -> AccessButtonCap { sockets[socket] ?? .pillow }
    var isDefault: Bool { sockets.values.allSatisfy { $0 == .pillow } && stick == .dome && tags.isEmpty }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sockets = try c.decodeIfPresent([Int: AccessButtonCap].self, forKey: .sockets) ?? [:]
        stick = try c.decodeIfPresent(AccessStickCap.self, forKey: .stick) ?? .dome
        tags = try c.decodeIfPresent([Int: Int].self, forKey: .tags) ?? [:]
    }

    /// The socket after this one around the ring (8 is next to 1), the
    /// one a wide flat cap on `socket` also covers.
    static func next(_ socket: Int) -> Int { socket % 8 + 1 }

    /// Sockets a wide flat cap on an earlier socket covers, so their own
    /// cap is not drawn. A wide cap on a socket already covered is ignored.
    var covered: Set<Int> {
        var out = Set<Int>()
        for s in 1...8 where cap(socket: s) == .wideFlat && !out.contains(s) {
            out.insert(Self.next(s))
        }
        return out
    }
}

/// The caps the user set, per controller unit, kept across launches.
@MainActor @Observable
final class AccessCapStore {
    static let shared = AccessCapStore()
    nonisolated static let defaultsKey = "InputConfig.accessCaps.v1"

    private(set) var sets: [String: AccessCapSet]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: AccessCapSet].self, from: data) {
            sets = decoded
        } else {
            sets = [:]
        }
    }

    func caps(for unit: String?) -> AccessCapSet { unit.flatMap { sets[$0] } ?? AccessCapSet() }

    func set(_ caps: AccessCapSet, for unit: String?) {
        guard let unit else { return }
        if caps.isDefault { sets.removeValue(forKey: unit) } else { sets[unit] = caps }
        if let data = try? JSONEncoder().encode(sets) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    func setSocket(_ socket: Int, to cap: AccessButtonCap, for unit: String?) {
        var c = caps(for: unit)
        // One wide flat cap covers two sockets: a wide cap on either
        // neighbor would overlap this one, so it comes off (the box has one).
        if cap == .wideFlat {
            let prev = (socket + 6) % 8 + 1
            for s in [prev, AccessCapSet.next(socket)] where c.sockets[s] == .wideFlat { c.sockets[s] = nil }
        }
        c.sockets[socket] = cap == .pillow ? nil : cap
        set(c, for: unit)
    }

    /// The tag on a socket's cap: an action code, or nil for the profile's.
    func setTag(_ socket: Int, to code: Int?, for unit: String?) {
        var c = caps(for: unit)
        c.tags[socket] = code
        set(c, for: unit)
    }

    func setStick(_ cap: AccessStickCap, for unit: String?) {
        var c = caps(for: unit)
        c.stick = cap
        set(c, for: unit)
    }
}

extension ControllerLayout {
    /// The center of the socket ring, and the drawing's width over height.
    static let psAccessRingCenter = CGPoint(x: 0.6309, y: 0.5)
    static let psAccessAspect = 191.0 / 141.0

    /// The drawing with the user's caps: each socket drawn as its cap, a
    /// wide flat cap as one long cap over two sockets that answers to
    /// both, and the stick as its cap.
    static func applyingAccessCaps(_ caps: AccessCapSet, to layout: ControllerLayout) -> ControllerLayout {
        guard !caps.isDefault else { return layout }
        var layout = layout
        let covered = caps.covered
        let byID = Dictionary(layout.controls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ring = psAccessRingCenter, aspect = psAccessAspect
        // Positions in width units, so directions are true on screen.
        func flat(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y / aspect) }
        func outward(_ p: CGPoint) -> CGVector {
            let a = flat(p), c = flat(ring)
            let dx = a.x - c.x, dy = a.y - c.y, len = max(0.0001, (dx * dx + dy * dy).squareRoot())
            return CGVector(dx: dx / len, dy: dy / len)
        }
        layout.controls = layout.controls.compactMap { c in
            if c.id == "stick" {
                var out = c
                switch caps.stick {
                case .dome: out.size = 0.17
                case .standard: out.size = 0.135
                case .ball: out.size = 0.1
                }
                return out
            }
            guard c.id.hasPrefix("socket"), let n = Int(c.id.dropFirst(6)) else { return c }
            if covered.contains(n) { return nil }
            var out = c
            // A tag the user clipped in shows over the profile's function.
            if let tag = caps.tags[n] {
                let label = accessCapLabel(code: tag, socket: n)
                out.symbol = label.symbol; out.printed = label.printed
            }
            let d = outward(c.center)
            switch caps.cap(socket: n) {
            case .pillow:
                break
            case .flat:
                out.shape = .circle
                out.size = 0.15; out.height = nil
            case .curve:
                out.shape = .curve(angleDegrees: atan2(d.dx, -d.dy) * 180 / .pi)
                out.size = 0.2; out.height = 0.2
            case .overhang:
                // Moved in toward the center button and long that way.
                let reach = 0.045
                out.center = CGPoint(x: c.center.x - d.dx * reach, y: c.center.y - d.dy * reach * aspect)
                out.shape = .capsule(angleDegrees: atan2(d.dy, d.dx) * 180 / .pi)
                out.size = 0.21; out.height = 0.12
            case .wideFlat:
                let m = AccessCapSet.next(n)
                guard let other = byID["socket\(m)"] else { break }
                let a = flat(c.center), b = flat(other.center)
                let dx = b.x - a.x, dy = b.y - a.y, len = (dx * dx + dy * dy).squareRoot()
                out.center = CGPoint(x: (c.center.x + other.center.x) / 2, y: (c.center.y + other.center.y) / 2)
                out.shape = .capsule(angleDegrees: atan2(dy, dx) * 180 / .pi)
                out.size = len + 0.13; out.height = 0.13
                // Either socket under it presses it.
                out.inputs.buttons += other.inputs.buttons.filter { !out.inputs.buttons.contains($0) }
                if out.inputs.hat == nil { out.inputs.hat = other.inputs.hat; out.inputs.hatDirection = other.inputs.hatDirection }
                out.name = String(localized: "Sockets \(n) and \(m)")
                out.note = String(localized: "A wide flat cap over sockets \(n) and \(m); pressing either lights it.")
                // Only the bare number is renamed: a function word or a tag
                // (L1, Create) stays as printed.
                if out.symbol == nil, out.printed == String(n) { out.printed = "\(n)+\(m)" }
            case .bare:
                out.shape = .circle
                out.size = 0.06; out.height = nil
                out.note = String(localized: "Socket \(n) with no cap on it")
            }
            return out
        }
        return layout
    }
}
