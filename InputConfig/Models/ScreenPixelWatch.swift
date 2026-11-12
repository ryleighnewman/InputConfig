import Foundation
import CoreGraphics

/// How a screen color row fires.
enum ScreenPixelMode: String, Codable, CaseIterable, Identifiable {
    /// Held, like a button, while the pixel is within the tolerance of the
    /// watch's color.
    case match
    /// A short press each time the pixel changes by more than the tolerance
    /// from what it showed on the last sample: something happened there.
    case change

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .match: return String(localized: "While the color shows")
        case .change: return String(localized: "When the color changes")
        }
    }
}

/// A point on a display and the color a row waits for there. Lives in the
/// preset (`Preset.screenPixels`), the way screen regions do, and is read
/// by `ScreenPixelService` while the preset runs.
///
/// `x` and `y` are 0 to 1 from the top left of the display named by
/// `display`; with no display, or one that is not attached, the main
/// display is used. Colors are sRGB 0 to 255 as the screen shows them.
/// `tolerance` is a fraction of the longest RGB distance (white to black),
/// so 0.12 lets the same color through at a slightly different brightness
/// and keeps a different color out.
struct ScreenPixelWatch: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var display: DisplayKey? = nil
    var x: Double = 0.5
    var y: Double = 0.5
    var red: Int = 255
    var green: Int = 255
    var blue: Int = 255
    var tolerance: Double = ScreenPixelWatch.defaultTolerance
    var mode: ScreenPixelMode = .match
    /// Palette slot, shared with the region maps so a row and its watch
    /// show the same color.
    var colorIndex: Int = 0

    static let defaultTolerance = 0.12
    static let maxWatches = 32

    /// The name as shown: the saved name, or the color and place.
    var shownName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let c = clampedValues()
        return String(localized: "Color at \(Int((c.x * 100).rounded()))%, \(Int((c.y * 100).rounded()))%")
    }

    /// "#FF8800" for the watch's color.
    var hexColor: String {
        String(format: "#%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
    }

    /// How far a sampled color is from the watch's, 0 (the same) to 1
    /// (white against black).
    func distance(toRed r: Int, green g: Int, blue b: Int) -> Double {
        let dr = Double(clamp(red) - r), dg = Double(clamp(green) - g), db = Double(clamp(blue) - b)
        return (dr * dr + dg * dg + db * db).squareRoot() / Self.maxDistance
    }

    /// White to black, the longest distance two colors can be apart.
    static let maxDistance = (3.0 * 255.0 * 255.0).squareRoot()

    /// Every number back inside its range, for a preset edited by hand.
    func clampedValues() -> ScreenPixelWatch {
        var w = self
        func finite(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback
        }
        w.x = finite(x, 0...1, 0.5)
        w.y = finite(y, 0...1, 0.5)
        w.red = clamp(red); w.green = clamp(green); w.blue = clamp(blue)
        w.tolerance = finite(tolerance, 0...1, Self.defaultTolerance)
        w.colorIndex = max(0, colorIndex)
        return w
    }

    private func clamp(_ v: Int) -> Int { min(255, max(0, v)) }

    // Tolerant decoding: a field a newer build adds, or one left out of a
    // hand-edited file, never drops the watch.
    enum CodingKeys: String, CodingKey {
        case id, name, display, x, y, red, green, blue, tolerance, mode, colorIndex
    }

    init() {}

    init(id: UUID = UUID(), name: String, display: DisplayKey?, x: Double, y: Double,
         red: Int, green: Int, blue: Int, tolerance: Double = ScreenPixelWatch.defaultTolerance,
         mode: ScreenPixelMode = .match, colorIndex: Int = 0) {
        self.id = id; self.name = name; self.display = display; self.x = x; self.y = y
        self.red = red; self.green = green; self.blue = blue; self.tolerance = tolerance
        self.mode = mode; self.colorIndex = colorIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        display = try? c.decodeIfPresent(DisplayKey.self, forKey: .display)
        x = (try? c.decode(Double.self, forKey: .x)) ?? 0.5
        y = (try? c.decode(Double.self, forKey: .y)) ?? 0.5
        red = (try? c.decode(Int.self, forKey: .red)) ?? 255
        green = (try? c.decode(Int.self, forKey: .green)) ?? 255
        blue = (try? c.decode(Int.self, forKey: .blue)) ?? 255
        tolerance = (try? c.decode(Double.self, forKey: .tolerance)) ?? Self.defaultTolerance
        mode = (try? c.decode(ScreenPixelMode.self, forKey: .mode)) ?? .match
        colorIndex = (try? c.decode(Int.self, forKey: .colorIndex)) ?? 0
        self = clampedValues()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(red, forKey: .red)
        try c.encode(green, forKey: .green)
        try c.encode(blue, forKey: .blue)
        try c.encode(tolerance, forKey: .tolerance)
        try c.encode(mode, forKey: .mode)
        try c.encode(colorIndex, forKey: .colorIndex)
    }
}
