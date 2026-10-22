import Foundation

/// Button and axis assignments for generic HID pads from SDL's community
/// GameControllerDB (the macOS rows, bundled in `SDLGameControllerDBData`).
/// Used after the hand-coded profiles miss and before the plain descriptor
/// layout, so an 8BitDo in DirectInput mode, a PowerA or Hori Switch pad, a
/// Logitech F310 or F710 in D mode, or a USB SNES pad reads A, B, X, Y, the
/// shoulders, and the sticks in the same slots as every other controller.
///
/// A row names each control by SDL's own numbering (b3, a1, h0.4), which on
/// macOS is the order `HIDDescriptorParser.sdlElements` rebuilds from the
/// descriptor. Anything a row leaves out is still read: unmapped buttons,
/// axes, and hats land on the extra slots, so no control is lost.
enum SDLGameControllerDB {

    struct Mapping: Equatable {
        let vendorID: Int32
        let productID: Int32
        let version: Int32
        let name: String
        /// Target (a, leftx, dpup...) to source (b3, a1~, +a2, h0.4...).
        let entries: [String: String]
    }

    /// Every macOS row, parsed once on first use.
    static let mappings: [Mapping] = parse(SDLGameControllerDBData.macOSRows)

    /// The row for a device: an exact version match first, then any row
    /// with the same vendor and product when every such row maps the
    /// controls the same way. When they differ (an unlisted firmware of a
    /// Logitech F710, some Xbox, DualShock 4 and Switch Pro pads), only
    /// rows whose buttons, axes and hats all exist on this pad's descriptor
    /// are considered, the one nearest this version first. SDL takes the
    /// first version-less row; a row naming controls the pad does not have
    /// belongs to another product sharing the IDs (cheap DragonRise and
    /// GreenAsia pads), so with none that fits the pad falls back to its
    /// descriptor's own layout.
    static func mapping(vendorID: Int32, productID: Int32, version: Int32?,
                        elements: HIDDescriptorParser.SDLElements? = nil) -> Mapping? {
        let rows = mappings.filter { $0.vendorID == vendorID && $0.productID == productID }
        if let version, let exact = rows.first(where: { $0.version == version }) { return exact }
        guard let first = rows.first else { return nil }
        if rows.allSatisfy({ $0.entries == first.entries }) { return first }
        guard let elements else { return nil }
        let fitting = rows.filter { fits($0, elements) }
        let v = version ?? 0
        // Nearest version; on a tie the newer firmware's row, which tends to
        // name more controls.
        return fitting.min { (abs($0.version - v), -$0.version) < (abs($1.version - v), -$1.version) }
    }

    /// Whether every source a row names (b3, a1, +a2, a1~, h0.4) exists on
    /// the pad.
    static func fits(_ row: Mapping, _ elements: HIDDescriptorParser.SDLElements) -> Bool {
        row.entries.values.allSatisfy { source in
            var s = Substring(source)
            if s.first == "+" || s.first == "-" { s = s.dropFirst() }
            if s.last == "~" { s = s.dropLast() }
            guard let kind = s.first else { return false }
            let digits = s.dropFirst().prefix { $0.isNumber }
            guard let index = Int(digits) else { return false }
            switch kind {
            case "b": return index < elements.buttons.count
            case "a": return index < elements.axes.count
            case "h": return index < elements.hats.count
            default: return false
            }
        }
    }

    static func parse(_ text: String) -> [Mapping] {
        var out: [Mapping] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > 2, let ids = ids(fromGUID: parts[0]), ids.vendor != 0 else { continue }
            var entries: [String: String] = [:]
            for part in parts.dropFirst(2) {
                let pair = part.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2, pair[0] != "platform" else { continue }
                entries[pair[0]] = pair[1]
            }
            out.append(Mapping(vendorID: ids.vendor, productID: ids.product, version: ids.version,
                               name: parts[1], entries: entries))
        }
        return out
    }

    /// Vendor, product, and version from an SDL joystick GUID: 16 bytes,
    /// little-endian 16-bit fields, bus at 0, vendor at 4, product at 8,
    /// version at 12.
    static func ids(fromGUID guid: String) -> (vendor: Int32, product: Int32, version: Int32)? {
        guard guid.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var index = guid.startIndex
        while index < guid.endIndex {
            let next = guid.index(index, offsetBy: 2)
            guard let byte = UInt8(guid[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        func word(_ at: Int) -> Int32 { Int32(bytes[at]) | (Int32(bytes[at + 1]) << 8) }
        // A vendor and product GUID has zeros between its fields. A GUID
        // built from a name or a CRC does not, and reading it as IDs gave
        // made-up vendor and product numbers ("SteelSeries Nimbus Plus" as
        // 4948:6544), which a real device could happen to match.
        // Bytes 2 and 3 can hold a CRC of the name (SDL 2.26 and later), so
        // only the gaps after the vendor and product must be zero.
        guard word(6) == 0, word(10) == 0 else { return nil }
        return (word(4), word(8), word(12))
    }

    // MARK: - Decode plan

    /// InputConfig's button slot for each SDL button target.
    static let buttonSlots: [String: Int] = [
        "a": 0, "b": 1, "x": 2, "y": 3,
        "leftshoulder": 4, "rightshoulder": 5,
        "lefttrigger": 6, "righttrigger": 7,
        "back": 8, "start": 9, "guide": 10,
        "leftstick": 11, "rightstick": 12,
        "touchpad": 13, "misc1": 14,
        // SDL's paddle1 and paddle3 are on the right, 2 and 4 on the left.
        // A two-paddle pad (a DualSense Edge) gets left 16, right 17; an
        // Xbox Elite takes xboxPaddleSlots instead.
        "paddle2": 16, "paddle1": 17, "paddle4": 18, "paddle3": 19,
    ]

    /// An Xbox pad's paddles on the slots GameController gives them: P1
    /// (SDL paddle1, upper right) 16, P2 (paddle3) 17, P3 (paddle2) 18,
    /// P4 (paddle4) 19, so a preset reads the same paddle on either path.
    static let xboxPaddleSlots: [String: Int] = ["paddle1": 16, "paddle3": 17, "paddle2": 18, "paddle4": 19]

    /// InputConfig's axis slot for each SDL axis target.
    static let axisSlots: [String: Int] = [
        "leftx": 0, "lefty": 1, "rightx": 2, "righty": 3,
        "lefttrigger": 4, "righttrigger": 5,
    ]

    /// First slot for buttons the row does not name.
    static let firstExtraButton = 22

    /// Names by button slot, for the profile.
    static func buttonNames(count: Int) -> [String] {
        let known: [Int: String] = [
            0: "A", 1: "B", 2: "X", 3: "Y", 4: "LB", 5: "RB", 6: "LT", 7: "RT",
            8: "Back", 9: "Start", 10: "Guide", 11: "L3", 12: "R3",
            13: "Touchpad", 14: "Misc", 16: "Left Paddle", 17: "Right Paddle",
            18: "Left Paddle 2", 19: "Right Paddle 2",
        ]
        return (0..<count).map { known[$0] ?? "Button \($0)" }
    }

    static func layout(for elements: HIDDescriptorParser.SDLElements,
                       mapping row: Mapping) -> HIDExtendedLayout? {
        let mapping = completed(row, buttonCount: elements.buttons.count)
        var buttons: [(Int?, HIDExtendedLayout.Button)] = []
        var axes: [(Int?, HIDExtendedLayout.Axis)] = []
        var hats: [(Int?, HIDExtendedLayout.Hat)] = []
        var dpad: [(Int?, HIDExtendedLayout.DpadButton)] = []
        var usedButtons = Set<Int>(), usedAxes = Set<Int>(), usedHats = Set<Int>()
        var mappedCount = 0
        let isXbox = mapping.name.localizedCaseInsensitiveContains("xbox")

        func axis(_ e: HIDDescriptorParser.SDLElement, slot: Int, unipolar: Bool,
                  half: Character?, inverted: Bool) -> HIDExtendedLayout.Axis {
            var lo = e.rangeMin, hi = e.rangeMax
            var flip = inverted
            if let half {
                let mid = lo + (hi - lo + 1) / 2
                if half == "+" { lo = mid } else { hi = mid; flip.toggle() }
            }
            return HIDExtendedLayout.Axis(bitOffset: e.bitOffset, bitSize: e.bitSize,
                                          logicalMin: lo, logicalMax: hi, isSigned: e.isSigned,
                                          usagePage: e.usagePage, usage: e.usage, index: slot,
                                          unipolar: unipolar, digitalButton: nil, inverted: flip)
        }
        func hat(_ e: HIDDescriptorParser.SDLElement, slot: Int) -> HIDExtendedLayout.Hat {
            let span = e.logicalMax - e.logicalMin + 1
            return HIDExtendedLayout.Hat(bitOffset: e.bitOffset, bitSize: e.bitSize,
                                         logicalMin: span == 4 || span == 8 ? e.logicalMin : 0,
                                         directions: span == 4 ? 4 : 8, index: slot)
        }

        for (target, source) in mapping.entries.sorted(by: { $0.key < $1.key }) {
            var src = Substring(source)
            var half: Character? = nil
            if let first = src.first, first == "+" || first == "-" { half = first; src = src.dropFirst() }
            var inverted = false
            if src.hasSuffix("~") { inverted = true; src = src.dropLast() }
            guard let kind = src.first else { continue }
            let rest = src.dropFirst()

            switch kind {
            case "b":
                guard let n = Int(rest) else { continue }
                guard n < elements.buttons.count else { return nil }
                let e = elements.buttons[n]
                // A pressure button (an 8-bit field) reads its whole field
                // and is pressed a sixteenth of the way in, close to SDL's
                // "any value above rest". Its top bit alone needed half
                // pressure, and a 0..1 field declared wide never pressed.
                let size = min(32, max(1, e.bitSize))
                let rest = size > 1 ? e.rangeMin + max(0, (e.rangeMax - e.rangeMin) / 16) : 0
                // Marked used only once placed: a target with no slot here
                // (misc2 to misc4) falls through to the extra buttons below
                // instead of not being read at all.
                if let direction = dpadDirection(target) {
                    dpad.append((e.reportID, .init(bitOffset: e.bitOffset, direction: direction, hatIndex: 0,
                                                   bitSize: size, pressAbove: rest)))
                    usedButtons.insert(n)
                    mappedCount += 1
                } else if let slot = (isXbox ? xboxPaddleSlots[target] : nil) ?? buttonSlots[target] {
                    buttons.append((e.reportID, .init(bitOffset: e.bitOffset, index: slot,
                                                      bitSize: size, pressAbove: rest)))
                    usedButtons.insert(n)
                    mappedCount += 1
                }
            case "a":
                guard let n = Int(rest) else { continue }
                guard n < elements.axes.count else { return nil }
                let e = elements.axes[n]
                if let direction = dpadDirection(target) {
                    // An axis D-pad (dpup:-a1): this half of the axis is the
                    // direction. Skipping these left USB SNES and NES style
                    // pads with no D-pad at all.
                    var positive = half != "-"
                    if inverted { positive.toggle() }
                    dpad.append((e.reportID, .init(bitOffset: e.bitOffset, direction: direction, hatIndex: 0,
                                                   axisHalf: .init(bitSize: e.bitSize, logicalMin: e.rangeMin,
                                                                   logicalMax: e.rangeMax, isSigned: e.isSigned,
                                                                   positive: positive))))
                } else if target == "lefttrigger" || target == "righttrigger" {
                    axes.append((e.reportID, axis(e, slot: axisSlots[target]!, unipolar: true,
                                                  half: half, inverted: inverted)))
                } else if let slot = axisSlots[target], half == nil {
                    axes.append((e.reportID, axis(e, slot: slot, unipolar: false,
                                                  half: nil, inverted: inverted)))
                } else {
                    continue   // A half stick: left unread.
                }
                usedAxes.insert(n)
                mappedCount += 1
            case "h":
                let bits = rest.split(separator: ".")
                guard bits.count == 2, let n = Int(bits[0]) else { continue }
                guard n < elements.hats.count else { return nil }
                // The hat is decoded with the standard directions, so a row
                // that rotates them (Mayflash Adapter 0E8F:3013: up is h0.4)
                // would turn every D-pad press; the plain layout is used.
                let standardMask = ["dpup": 1, "dpright": 2, "dpdown": 4, "dpleft": 8]
                if let expected = standardMask[target], Int(bits[1]) != expected { return nil }
                if usedHats.insert(n).inserted {
                    hats.append((elements.hats[n].reportID, hat(elements.hats[n], slot: 0)))
                }
                mappedCount += 1
            default:
                continue
            }
        }
        guard mappedCount >= 4 else { return nil }

        // An analog trigger also presses LT or RT when the row has no
        // button there, as on every other path.
        let buttonSlotsUsed = Set(buttons.map(\.1.index))
        for i in axes.indices where (axes[i].1.index == 4 || axes[i].1.index == 5)
            && !buttonSlotsUsed.contains(axes[i].1.index + 2) {
            axes[i].1.digitalButton = axes[i].1.index + 2
        }
        // A PlayStation shaped row (Square b0, Cross b1, Circle b2,
        // Triangle b3, triggers on axes) leaves the DualShock's digital L2
        // and R2 bits (b6, b7) unmapped. A Victrix Pro FS and GP2040-CE
        // boards set only those bits and leave the analog bytes at 0
        // (SDL_hidapi_ps4.c), so the bits also press L2 and R2 and force
        // the trigger axes full. The extras loop below still numbers the
        // same bits from 22, for presets that already use them.
        let dualShockShape = ["x": "b0", "a": "b1", "b": "b2", "y": "b3"].allSatisfy { mapping.entries[$0.key] == $0.value }
        if dualShockShape, mapping.entries["lefttrigger"]?.hasPrefix("a") == true, mapping.entries["righttrigger"]?.hasPrefix("a") == true {
            for (n, slot) in [(6, 6), (7, 7)] where !usedButtons.contains(n) && n < elements.buttons.count && elements.buttons[n].bitSize == 1 {
                let e = elements.buttons[n]
                buttons.append((e.reportID, .init(bitOffset: e.bitOffset, index: slot, forcesAxis: slot - 2)))
            }
        }
        // A row that names no stick (the Hori Pokken row GP2040-CE's Switch
        // mode inherits) on a device whose descriptor has X, Y and Z, Rz or
        // Rx, Ry: those go on the stick slots the plain layout would use.
        if ["leftx", "lefty", "rightx", "righty"].allSatisfy({ mapping.entries[$0] == nil }) {
            func unused(_ usage: Int) -> Int? {
                elements.axes.indices.first { !usedAxes.contains($0) && elements.axes[$0].usagePage == 0x01 && elements.axes[$0].usage == usage }
            }
            let pairs: [(Int, Int)] = [(0x30, 0), (0x31, 1)]
                + ((unused(0x32) != nil && unused(0x35) != nil) ? [(0x32, 2), (0x35, 3)] : [(0x33, 2), (0x34, 3)])
            for (usage, slot) in pairs {
                guard let n = unused(usage) else { continue }
                axes.append((elements.axes[n].reportID, axis(elements.axes[n], slot: slot, unipolar: false, half: nil, inverted: false)))
                usedAxes.insert(n)
            }
        }

        // Unmapped controls keep working on the extra slots.
        var nextButton = firstExtraButton
        for (n, e) in elements.buttons.enumerated() where !usedButtons.contains(n) && e.bitSize == 1 {
            buttons.append((e.reportID, .init(bitOffset: e.bitOffset, index: nextButton)))
            nextButton += 1
        }
        var nextAxis = 6
        for (n, e) in elements.axes.enumerated() where !usedAxes.contains(n) && e.bitSize >= 2 {
            axes.append((e.reportID, axis(e, slot: nextAxis, unipolar: false, half: nil, inverted: false)))
            nextAxis += 1
        }
        var nextHat = usedHats.isEmpty && dpad.isEmpty ? 0 : 1
        for (n, e) in elements.hats.enumerated() where !usedHats.contains(n) {
            hats.append((e.reportID, hat(e, slot: nextHat)))
            nextHat += 1
        }

        // One report entry per report ID, the busiest first.
        var keys: [Int?] = []
        for key in buttons.map(\.0) + axes.map(\.0) + hats.map(\.0) + dpad.map(\.0) where !keys.contains(key) {
            keys.append(key)
        }
        func count(_ key: Int?) -> Int {
            buttons.filter { $0.0 == key }.count + axes.filter { $0.0 == key }.count
                + hats.filter { $0.0 == key }.count + dpad.filter { $0.0 == key }.count
        }
        keys.sort { count($0) > count($1) }
        let reports = keys.map { key in
            HIDExtendedLayout.Report(
                reportID: key,
                payloadSize: elements.payloadSizes[key] ?? 0,
                buttons: buttons.filter { $0.0 == key }.map(\.1).sorted { $0.index < $1.index },
                axes: axes.filter { $0.0 == key }.map(\.1).sorted { $0.index < $1.index },
                hats: hats.filter { $0.0 == key }.map(\.1).sorted { $0.index < $1.index },
                dpadButtons: dpad.filter { $0.0 == key }.map(\.1))
        }
        return HIDExtendedLayout(usesReportIDs: elements.usesReportIDs, reports: reports)
    }

    private static func dpadDirection(_ target: String) -> HIDExtendedLayout.DpadButton.Direction? {
        switch target {
        case "dpup": return .up
        case "dpdown": return .down
        case "dpleft": return .left
        case "dpright": return .right
        default: return nil
        }
    }

    /// A ready profile for a device the database knows, or nil.
    static func profile(descriptor: Data, vendorID: Int32, productID: Int32,
                        version: Int32?, productName: String) -> ControllerProfile? {
        guard let elements = HIDDescriptorParser.sdlElements(descriptor),
              let mapping = mapping(vendorID: vendorID, productID: productID, version: version, elements: elements)
                ?? playStationClassMapping(vendorID: vendorID, productID: productID, elements: elements),
              let extended = layout(for: elements, mapping: mapping) else { return nil }
        var generic = extended.legacyLayout
        generic.extended = extended
        let topButton = extended.reports.flatMap(\.buttons).map(\.index).max() ?? -1
        return ControllerProfile(
            identifier: "sdl-\(vendorID)-\(productID)",
            displayName: productName,
            vendorID: vendorID,
            productMatches: [.exact(productID)],
            layout: .generic(generic),
            physicalButtonNames: buttonNames(count: topButton + 1)
        )
    }
}
