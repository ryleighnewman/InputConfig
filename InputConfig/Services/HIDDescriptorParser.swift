import Foundation

/// Parses a HID report descriptor at runtime and synthesizes a
/// `ControllerProfile.GenericLayout` describing where each button,
/// axis, hat, and trigger lives in the input report. Lets
/// `RawHIDGamepadService` support gamepads we have never seen
/// without a hand-coded entry in `ControllerProfileDatabase`.
///
/// The HID 1.11 spec (section 6.2.2) defines a descriptor as a
/// sequence of "items". Each short item is one prefix byte followed
/// by 0/1/2/4 bytes of data. The prefix encodes the item's type
/// (Main / Global / Local), tag (e.g. INPUT, USAGE_PAGE), and data
/// size. We walk the byte stream maintaining a small parser state
/// (current usage page, logical min/max, report size, report count,
/// pending usages list). When an INPUT item fires we record one or
/// more fields with their bit offset, size, and usage, then advance
/// a per-report bit cursor by `report_size * report_count`.
///
/// What we recognize:
///   - Button usage page (0x09) - one bit per button
///   - Generic Desktop axes (X/Y/Z/Rx/Ry/Rz, Slider, Dial, Wheel) - any
///     width from 2 to 32 bits, at any bit offset, scaled by the declared
///     logical range
///   - Simulation Controls axes (Rudder, Throttle, Accelerator, Brake,
///     Steering)
///   - Generic Desktop Hat switch (0x39) - 4 or 8 directions, any count
///   - Constant fields - skipped (just advances the bit cursor)
///   - PUSH / POP of the global state, and 4-byte extended usages
///
/// What we skip on purpose:
///   - Long items (rare, different format)
///   - Array (non-variable) inputs
///   - Vendor-specific usage pages (we can't map them generically)
///
/// The full decode plan (logical ranges, bit sizes, every hat, every
/// input report) rides on the returned layout as `extended`, which
/// `HIDReportDecoder` uses directly.
enum HIDDescriptorParser {

    /// Returns nil when the descriptor doesn't yield a useful layout
    /// (no buttons, axes, or hats), in which case the caller should fall
    /// back to logging the device as unidentified.
    ///
    /// Multi-report-ID devices are supported: fields and bit cursors are
    /// tracked per input report ID. The returned layout describes the
    /// input report with the richest control set (ties go to the lowest
    /// ID), and the extended layout also decodes every other input report
    /// that carries controls the primary one lacks (a SpaceMouse sends
    /// translation, rotation, and buttons in three separate reports).
    /// All recorded offsets are PAYLOAD-relative: for devices with
    /// report IDs they count from the byte after the leading ID byte,
    /// matching how `decodeGeneric` strips it before indexing.
    static func parse(_ descriptor: Data) -> ControllerProfile.GenericLayout? {
        guard let extended = parseExtended(descriptor) else { return nil }
        var layout = extended.legacyLayout
        layout.extended = extended
        return layout
    }

    /// Two-player adapters on one interface (a Twin USB PS1/PS2 adapter, a
    /// dual arcade encoder) send each player as its own report ID with the
    /// same controls. The main layout reads the first player; this returns
    /// a layout for each other player's report, so each gets its own slot.
    /// Reports that add controls the main one lacks (a SpaceMouse) are not
    /// players and are merged as before.
    static func playerLayouts(_ descriptor: Data) -> [(reportID: Int, layout: ControllerProfile.GenericLayout)] {
        let (fieldsByReport, cursorByReport, arraysByReport) = collectFields(descriptor)
        let keys = fieldsByReport.keys.compactMap { $0 }.sorted()
        guard keys.count >= 2, fieldsByReport[nil] == nil else { return [] }
        func signature(_ fields: [Field]) -> [Int] {
            fields.filter { isControl($0) }.map { ($0.usagePage << 16) | $0.usage }.sorted()
        }
        // The first player is the richest report, as in buildLayout.
        guard let primary = keys.max(by: { a, b in
            let sa = controlScore(fieldsByReport[a] ?? []), sb = controlScore(fieldsByReport[b] ?? [])
            return sa == sb ? a > b : sa < sb
        }) else { return [] }
        let primarySignature = signature(fieldsByReport[primary] ?? [])
        guard primarySignature.count >= 4 else { return [] }
        var players: [(Int, ControllerProfile.GenericLayout)] = []
        for key in keys where key != primary && signature(fieldsByReport[key] ?? []) == primarySignature {
            guard let extended = buildLayout(fieldsByReport: [key: fieldsByReport[key] ?? []],
                                             cursorByReport: [key: cursorByReport[key] ?? 0],
                                             arraysByReport: [key: arraysByReport[key] ?? []]) else { continue }
            var layout = extended.legacyLayout
            layout.extended = extended
            players.append((key, layout))
        }
        return players
    }

    /// True when two reports carry the same controls at the same bit
    /// offsets, so a plan for one reads the other by changing its ID.
    static func reportsShareLayout(_ descriptor: Data, _ a: Int, _ b: Int) -> Bool {
        let (fieldsByReport, cursorByReport, _) = collectFields(descriptor)
        func shape(_ id: Int) -> [[Int]] {
            (fieldsByReport[id] ?? []).filter { isControl($0) }
                .map { [$0.usagePage, $0.usage, $0.bitOffset, $0.bitSize, $0.logicalMin, $0.logicalMax] }
        }
        let sa = shape(a)
        return !sa.isEmpty && sa == shape(b) && cursorByReport[a] == cursorByReport[b]
    }

    /// Whether 1.6 could read this descriptor: some report has a control of
    /// the kinds read before 1.7. A device it could not read, connected by
    /// hand, was read bit by bit, and its presets use those bit numbers.
    static func readableBefore17(_ descriptor: Data) -> Bool {
        let (fieldsByReport, _, _) = collectFields(descriptor)
        return fieldsByReport.values.contains { controlScore($0) > 0 }
    }

    /// Full decode plan for a descriptor.
    static func parseExtended(_ descriptor: Data) -> HIDExtendedLayout? {
        let (fieldsByReport, cursorByReport, arraysByReport) = collectFields(descriptor)
        return buildLayout(fieldsByReport: fieldsByReport, cursorByReport: cursorByReport,
                           arraysByReport: arraysByReport)
    }

    /// Every variable input field, per report ID, plus each report's bit
    /// length, and the array inputs (a field holding which buttons are down)
    /// on their own, so nothing that numbers the variable fields sees them.
    private static func collectFields(_ descriptor: Data) -> (fields: [Int?: [Field]], cursors: [Int?: Int], arrays: [Int?: [ArrayInput]]) {
        var state = ParseState()
        var sequence = 0
        var globalStack: [GlobalState] = []
        // Key nil = device without REPORT_ID items.
        var fieldsByReport: [Int?: [Field]] = [:]
        var cursorByReport: [Int?: Int] = [:]
        var arraysByReport: [Int?: [ArrayInput]] = [:]

        let bytes = Array(descriptor)
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            i += 1

            // Long item prefix (1111 1110). Skip; format is different
            // and almost never used in gamepads. Clamp the advance to
            // bytes.count so a truncated descriptor with a malicious
            // longSize byte can't overshoot the buffer.
            if prefix == 0xFE {
                if i + 1 < bytes.count {
                    let longSize = Int(bytes[i])
                    i = min(bytes.count, i + 2 + longSize)
                } else {
                    break
                }
                continue
            }

            let dataSizeCode = prefix & 0x03
            let dataSize = dataSizeCode == 3 ? 4 : Int(dataSizeCode)
            let itemType = (prefix >> 2) & 0x03
            let itemTag = (prefix >> 4) & 0x0F

            // Read data payload (little endian)
            var rawData: UInt32 = 0
            if dataSize > 0 {
                guard i + dataSize <= bytes.count else { break }
                for b in 0..<dataSize {
                    rawData |= UInt32(bytes[i + b]) << (8 * b)
                }
                i += dataSize
            }

            // Some items (LOGICAL_MIN/MAX) carry signed values - sign
            // extend if the high bit is set. Guard `bits < 32` because
            // `UInt32.max << 32` is undefined behavior - for a full
            // 4-byte value the rawData is already 32 bits wide and the
            // bitPattern conversion handles the sign correctly without
            // extension.
            let signedData: Int = {
                guard dataSize > 0 else { return Int(rawData) }
                let bits = dataSize * 8
                if bits >= 32 {
                    return Int(Int32(bitPattern: rawData))
                }
                let signBit = UInt32(1) << (bits - 1)
                if rawData & signBit != 0 {
                    let extended = rawData | (UInt32.max << bits)
                    return Int(Int32(bitPattern: extended))
                }
                return Int(rawData)
            }()

            // A 4-byte USAGE / USAGE_MINIMUM / USAGE_MAXIMUM is an
            // extended usage: page in the high 16 bits, usage in the low.
            let localUsage = Usage(page: dataSize == 4 ? Int(rawData >> 16) : nil,
                                   id: dataSize == 4 ? Int(rawData & 0xFFFF) : Int(rawData))

            switch itemType {

            case 0: // Main
                switch itemTag {
                case 0x8: // INPUT
                    let dataFlag = rawData
                    let isConstant = (dataFlag & 0x01) != 0
                    let isVariable = (dataFlag & 0x02) != 0
                    let isRelative = (dataFlag & 0x04) != 0
                    let g = state.global
                    let bitsPerEntry = g.reportSize

                    // Skip malformed descriptors that emit INPUT before
                    // REPORT_SIZE/REPORT_COUNT - they would overlay the
                    // previous entry at the same bit offset and produce
                    // garbage layouts. Better to bail than mis-decode.
                    // Also cap absurd values so a hostile descriptor
                    // (reportSize=0xFFFFFFFF, reportCount=0xFFFFFFFF)
                    // can't trap on integer overflow in the multiply.
                    guard g.reportSize > 0 && g.reportCount > 0,
                          g.reportSize <= 256,
                          g.reportCount <= 1024 else {
                        state.clearLocals()
                        break
                    }
                    let (mulResult, mulOverflow) = bitsPerEntry.multipliedReportingOverflow(by: g.reportCount)
                    if mulOverflow {
                        state.clearLocals()
                        break
                    }
                    let totalBits = mulResult

                    // Input fields recorded before any REPORT_ID belong to
                    // the first report that INPUT items are read under. Their
                    // offsets are already payload-relative, so no shift.
                    if let id = g.reportID {
                        if let orphans = fieldsByReport[Int?.none], !orphans.isEmpty {
                            fieldsByReport[id, default: []].append(contentsOf: orphans)
                        }
                        fieldsByReport[Int?.none] = nil
                        if let orphans = arraysByReport[Int?.none], !orphans.isEmpty {
                            arraysByReport[id, default: []].append(contentsOf: orphans)
                        }
                        arraysByReport[Int?.none] = nil
                        if let orphanCursor = cursorByReport[Int?.none] {
                            cursorByReport[id, default: 0] += orphanCursor
                        }
                        cursorByReport[Int?.none] = nil
                    }

                    if !isConstant && isVariable {
                        // Distribute usages across the report count.
                        // If we have explicit usages they map 1:1; if
                        // we have a usage range (min/max), each entry
                        // gets a usage from the range.
                        let base = cursorByReport[g.reportID, default: 0]
                        let range = resolvedRange(bitSize: bitsPerEntry,
                                                  logicalMin: g.logicalMin,
                                                  logicalMaxSigned: g.logicalMax,
                                                  logicalMaxUnsigned: g.logicalMaxUnsigned)
                        for n in 0..<g.reportCount {
                            let usage = state.usage(forIndex: n)
                            fieldsByReport[g.reportID, default: []].append(Field(
                                bitOffset: base + n * bitsPerEntry,
                                bitSize: bitsPerEntry,
                                usagePage: usage.page ?? g.usagePage,
                                usage: usage.id,
                                logicalMin: g.logicalMin,
                                logicalMax: g.logicalMax,
                                rangeMin: range.min,
                                rangeMax: range.max,
                                isSigned: range.signed,
                                sequence: sequence,
                                isRelative: isRelative
                            ))
                            sequence += 1
                        }
                    }

                    // An array input: each entry holds the number of a
                    // control that is down (button boxes, some arcade
                    // encoders, Android pads' Home and Back), not one bit
                    // per control. Kept when its controls are buttons.
                    if !isConstant && !isVariable,
                       let usages = state.arrayUsages(logicalMin: g.logicalMin, logicalMax: g.logicalMax),
                       bitsPerEntry <= 16 {
                        let base = cursorByReport[g.reportID, default: 0]
                        arraysByReport[g.reportID, default: []].append(ArrayInput(
                            bitOffset: base,
                            bitSize: bitsPerEntry,
                            count: g.reportCount,
                            logicalMin: g.logicalMin,
                            usagePage: usages.page ?? g.usagePage,
                            usages: usages.ids))
                    }

                    cursorByReport[g.reportID, default: 0] += totalBits
                    state.clearLocals()

                case 0x9, 0xB: // OUTPUT / FEATURE
                    // Output and feature reports occupy their own bit
                    // spaces. Advancing the INPUT cursor here shifted
                    // every later input field on devices with rumble or
                    // LED output items and inflated reportSize, so the
                    // decoder's size guard rejected every real report.
                    // (The old advance also multiplied unguarded, which
                    // a hostile descriptor could overflow.)
                    // A REPORT_ID read for this item alone, after input items
                    // without one, labels only the Output or Feature report:
                    // later inputs stay ID-less like the ones before.
                    if state.global.reportID != nil, cursorByReport[Int?.none] != nil {
                        state.global.reportID = nil
                    }
                    state.clearLocals()

                case 0xA: // COLLECTION
                    state.clearLocals()

                case 0xC: // END COLLECTION
                    state.clearLocals()

                default: break
                }

            case 1: // Global
                switch itemTag {
                case 0x0: state.global.usagePage = Int(rawData)
                case 0x1: state.global.logicalMin = signedData
                case 0x2:
                    state.global.logicalMax = signedData
                    state.global.logicalMaxUnsigned = Int(rawData)
                case 0x7: state.global.reportSize = Int(rawData)
                case 0x8:
                    // REPORT_ID - the first byte of every report is the
                    // ID. Switch the active per-report bookkeeping; each
                    // report ID gets its own payload-relative cursor.
                    // Input fields recorded before it (malformed but seen
                    // in the wild) move to that report only once an INPUT
                    // item is read under the ID: an ID that labels just an
                    // Output or Feature item does not own the pad's input.
                    state.global.reportID = Int(rawData)
                case 0x9: state.global.reportCount = Int(rawData)
                case 0xA: // PUSH - save the whole global state
                    // Capped so a hostile descriptor can't grow the stack
                    // without bound; real descriptors nest one or two deep.
                    if globalStack.count < 64 {
                        globalStack.append(state.global)
                    }
                case 0xB: // POP
                    if let saved = globalStack.popLast() {
                        state.global = saved
                    }
                default: break
                }

            case 2: // Local
                switch itemTag {
                case 0x0: state.usages.append(localUsage)
                case 0x1:
                    state.usageMin = localUsage
                    state.hasUsageMin = true
                case 0x2:
                    state.usageMax = localUsage
                    state.hasUsageMax = true
                default: break
                }

            default: break
            }
        }

        return (fieldsByReport, cursorByReport, arraysByReport)
    }

    /// One array input item: `count` entries of `bitSize` bits, each the
    /// number of a control that is down, counted from `logicalMin`.
    struct ArrayInput: Equatable {
        let bitOffset: Int
        let bitSize: Int
        let count: Int
        let logicalMin: Int
        let usagePage: Int
        /// The usage for each value from logicalMin up.
        let usages: [Int]
    }

    // MARK: - SDL element order

    /// One control as SDL's macOS joystick backend numbers it.
    struct SDLElement: Equatable {
        var reportID: Int?
        var bitOffset: Int
        var bitSize: Int
        var rangeMin: Int
        var rangeMax: Int
        var isSigned: Bool
        var usagePage: Int
        var usage: Int
        var logicalMin: Int
        var logicalMax: Int
    }

    /// The device's buttons, axes, and hats in the order SDL's IOKit
    /// backend numbers them (b0, a0, h0 in a GameControllerDB row): each
    /// list sorted by usage number alone, ties kept in descriptor order.
    /// Buttons include the Consumer page and the Generic Desktop D-pad,
    /// Start, Select, and System Main Menu usages; axes are X through
    /// Wheel plus Rudder, Throttle, Accelerator, and Brake.
    struct SDLElements: Equatable {
        var buttons: [SDLElement]
        var axes: [SDLElement]
        var hats: [SDLElement]
        var usesReportIDs: Bool
        /// Payload bytes per report ID.
        var payloadSizes: [Int?: Int]
    }

    static func sdlElements(_ descriptor: Data) -> SDLElements? {
        let (fieldsByReport, cursorByReport, _) = collectFields(descriptor)
        guard !fieldsByReport.isEmpty else { return nil }
        var all: [(Field, Int?)] = []
        for (key, fields) in fieldsByReport { all += fields.map { ($0, key) } }
        all.sort { $0.0.sequence < $1.0.sequence }

        func element(_ f: Field, _ key: Int?) -> SDLElement {
            SDLElement(reportID: key, bitOffset: f.bitOffset, bitSize: f.bitSize,
                       rangeMin: f.rangeMin, rangeMax: f.rangeMax, isSigned: f.isSigned,
                       usagePage: f.usagePage, usage: f.usage,
                       logicalMin: f.logicalMin, logicalMax: f.logicalMax)
        }
        var buttons: [SDLElement] = [], axes: [SDLElement] = [], hats: [SDLElement] = []
        for (f, key) in all {
            switch f.usagePage {
            case 0x01:
                switch f.usage {
                case 0x30...0x38: axes.append(element(f, key))
                case 0x39: hats.append(element(f, key))
                case 0x90...0x93, 0x3D, 0x3E, 0x85: buttons.append(element(f, key))
                default: break
                }
            case 0x02:
                if [0xBA, 0xBB, 0xC4, 0xC5].contains(f.usage) { axes.append(element(f, key)) }
            case 0x09, 0x0C:
                buttons.append(element(f, key))
            default:
                break
            }
        }
        // Stable sort by usage, as SDL inserts each element after every
        // element with a lower or equal usage.
        func sortedByUsage(_ list: [SDLElement]) -> [SDLElement] {
            list.enumerated().sorted { a, b in
                a.element.usage != b.element.usage ? a.element.usage < b.element.usage : a.offset < b.offset
            }.map(\.element)
        }
        let sizes = Dictionary(uniqueKeysWithValues: cursorByReport.map { ($0.key, ($0.value + 7) / 8) })
        return SDLElements(buttons: sortedByUsage(buttons), axes: sortedByUsage(axes),
                           hats: sortedByUsage(hats),
                           usesReportIDs: fieldsByReport.keys.contains { $0 != nil },
                           payloadSizes: sizes)
    }

    // MARK: - Field aggregation

    private struct Usage {
        let page: Int?   // Set only for 4-byte extended usages
        let id: Int
    }

    private struct Field {
        let bitOffset: Int
        let bitSize: Int
        let usagePage: Int
        let usage: Int
        let logicalMin: Int
        let logicalMax: Int
        // Range the decoder scales by, after repairing the common
        // descriptor mistakes (see `resolvedRange`).
        let rangeMin: Int
        let rangeMax: Int
        let isSigned: Bool
        // Position in the descriptor, across every report.
        let sequence: Int
        // INPUT flag bit 2: a change since the last report (a mouse's X
        // and Y), not a position.
        var isRelative = false
    }

    /// The logical range a field is scaled by. HID says a negative
    /// LOGICAL_MINIMUM makes the field two's complement; otherwise it is
    /// unsigned. Two descriptor mistakes are common enough to repair:
    /// `26 FF FF` (0..65535 written as a 2-byte item, which sign extends
    /// to -1) is read unsigned, and a range that is inverted, degenerate,
    /// or wider than the field (cheap DragonRise-style encoder boards)
    /// degrades to the field's full unsigned span.
    private static func resolvedRange(bitSize: Int,
                                      logicalMin: Int,
                                      logicalMaxSigned: Int,
                                      logicalMaxUnsigned: Int) -> (min: Int, max: Int, signed: Bool) {
        guard bitSize >= 1 && bitSize <= 32 else { return (0, 0, false) }
        let unsignedMax = (1 << bitSize) - 1
        let signedMin = -(1 << (bitSize - 1))
        let signedMax = (1 << (bitSize - 1)) - 1
        var hi = logicalMaxSigned
        if logicalMin >= 0 && hi < logicalMin {
            hi = logicalMaxUnsigned
        }
        if logicalMin < hi {
            if logicalMin < 0 {
                if logicalMin >= signedMin && hi <= signedMax {
                    return (logicalMin, hi, true)
                }
            } else if hi <= unsignedMax {
                return (logicalMin, hi, false)
            }
        }
        return (0, unsignedMax, false)
    }

    /// One axis-like field plus its position in the device's reports, so
    /// assignments are deterministic across report IDs.
    private struct AxisCandidate {
        let field: Field
        let reportIndex: Int
        var order: (Int, Int) { (reportIndex, field.bitOffset) }
    }

    private static func buildLayout(fieldsByReport: [Int?: [Field]],
                                    cursorByReport: [Int?: Int],
                                    arraysByReport: [Int?: [ArrayInput]] = [:]) -> HIDExtendedLayout? {
        // Deterministic report order: nil (no IDs) first, then ascending.
        let keys = fieldsByReport.keys.sorted { ($0 ?? -1) < ($1 ?? -1) }
        guard !keys.isEmpty || !arraysByReport.isEmpty else { return nil }

        // The primary report is the one with the richest control set; a
        // tie goes to the lowest ID so the choice is stable run to run.
        var primary: Int?? = nil
        var bestScore = -1
        for key in keys {
            let score = controlScore(fieldsByReport[key] ?? [])
            if score > bestScore {
                bestScore = score
                primary = .some(key)
            }
        }
        // A device with none of the controls read before 1.7 (rudder pedals
        // on toe brake usages, a button box sending an array) is scored by
        // everything it has instead.
        if bestScore <= 0 {
            var allKeys = keys
            for key in arraysByReport.keys where !allKeys.contains(where: { $0 == key }) { allKeys.append(key) }
            allKeys.sort { ($0 ?? -1) < ($1 ?? -1) }
            for key in allKeys {
                let score = (fieldsByReport[key] ?? []).filter(isControl).count
                    + (arraysByReport[key] ?? []).filter { $0.usagePage == 0x09 || $0.usagePage == 0x0C }.count
                if score > bestScore {
                    bestScore = score
                    primary = .some(key)
                }
            }
        }
        guard let primaryKey = primary, bestScore > 0 else { return nil }
        let orderedKeys = [primaryKey] + keys.filter { $0 != primaryKey }

        // Walk the reports, keeping each field only if no earlier report
        // already provided the same control. That merges a SpaceMouse's
        // split reports into one device while ignoring the duplicate
        // player-two report of a two-player arcade encoder.
        var seenUsages = Set<Int>()
        var hatCountSeen = 0
        var keptFields: [[Field]] = []
        var keptKeys: [Int?] = []
        // A report with the same controls as an earlier one is a second
        // player (split off by playerLayouts) and adds nothing here. One
        // that repeats only some of them (a board with two differently
        // built joysticks, a two-port retro adapter) keeps its own buttons,
        // hats and axes: they are numbered after everything else, so earlier
        // numbers stay.
        var repeatedButtons: [[Field]] = []
        var signatures: [[Int]] = []
        func signature(_ fields: [Field]) -> [Int] {
            fields.filter { isControl($0) }.map { ($0.usagePage << 16) | $0.usage }.sorted()
        }
        for key in orderedKeys {
            var kept: [Field] = []
            var repeated: [Field] = []
            let fields = fieldsByReport[key] ?? []
            let sig = signature(fields)
            // The same rule as playerLayouts (four controls or more): a small
            // repeated report (an Atari stick per port, one switch per port)
            // stays on this pad as repeated controls, not dropped.
            let playerCopy = sig.count >= 4 && signatures.contains(sig)
            signatures.append(sig)
            let hatsHere = fields.filter { isHat($0) }.count
            let reportAddsHats = hatsHere > hatCountSeen
            var usagesHere = Set<Int>()
            for field in fields where isControl(field) {
                if isHat(field) {
                    if reportAddsHats { kept.append(field) } else if !playerCopy { repeated.append(field) }
                    continue
                }
                let full = (field.usagePage << 16) | field.usage
                // Repeats inside one report are kept (DragonRise declares
                // X four times); only repeats of an earlier report drop.
                if seenUsages.contains(full) {
                    // A mouse report's X and Y on a pad's interface move, not
                    // sit at a position, so they are not a second port.
                    if !playerCopy, (field.usagePage == 0x09 && field.bitSize == 1) || (isAxis(field) && !field.isRelative) { repeated.append(field) }
                    continue
                }
                usagesHere.insert(full)
                kept.append(field)
            }
            seenUsages.formUnion(usagesHere)
            if reportAddsHats { hatCountSeen = hatsHere }
            if !kept.isEmpty || !repeated.isEmpty || key == primaryKey {
                keptFields.append(kept)
                keptKeys.append(key)
                repeatedButtons.append(repeated)
            }
        }

        // Buttons in report order, then bit order.
        var buttonsPerReport: [[HIDExtendedLayout.Button]] = keptFields.map { _ in [] }
        var buttonCount = 0
        for (r, fields) in keptFields.enumerated() {
            for field in fields.sorted(by: { $0.bitOffset < $1.bitOffset })
            where field.usagePage == 0x09 && field.bitSize == 1 {
                buttonsPerReport[r].append(.init(bitOffset: field.bitOffset, index: buttonCount))
                buttonCount += 1
            }
        }
        let buttonPageCount = buttonCount
        // From 8 at the least, clear of the LT and RT slots (6 and 7) a
        // trigger axis is mirrored onto when the pad has few buttons.
        if buttonCount < 8 && keptFields.contains(where: { $0.contains(where: isExtraButton) }) { buttonCount = 8 }
        for (r, fields) in keptFields.enumerated() {
            for field in fields.sorted(by: { $0.bitOffset < $1.bitOffset }) where isExtraButton(field) {
                buttonsPerReport[r].append(.init(bitOffset: field.bitOffset, index: buttonCount))
                buttonCount += 1
            }
        }
        // Hats in report order, then bit order: hats[0], hats[1], ...
        var hatsPerReport: [[HIDExtendedLayout.Hat]] = keptFields.map { _ in [] }
        var hatCount = 0
        // Hats of the widths read before 1.7 first, so their numbers stay;
        // hats of other widths follow.
        // Then the hats of a report that repeats another's controls.
        let hatPasses: [(legacy: Bool?, source: [[Field]])] = [(true, keptFields), (false, keptFields), (nil, repeatedButtons)]
        for (pass, source) in hatPasses {
            for (r, fields) in source.enumerated() {
                for field in fields.sorted(by: { $0.bitOffset < $1.bitOffset })
                where isHat(field) && (pass == nil || isLegacyHat(field) == pass) {
                    // Directions from the declared span: 0..3 is a 4-way hat,
                    // 0..7 / 1..8 an 8-way one, and a wide span (0..315 or
                    // 0..35999) an angle, read whole. Anything else odd falls
                    // back to the 8-way reading with a 0 or 1 minimum.
                    let span = field.logicalMax - field.logicalMin + 1
                    // An angle needs at least 9 bits (0..315); a 4 or 8 bit
                    // hat with a wide range left over from the axes before
                    // it is an ordinary 8-way hat. Judged on the repaired
                    // range, so 0..35999 written as a 2-byte maximum (which
                    // reads as negative) still counts.
                    let wideSpan = field.rangeMax - field.rangeMin + 1
                    let angular = field.bitSize >= 9 && wideSpan > 16 && wideSpan <= (1 << field.bitSize)
                    // An angle hat counts degrees (0..315 for eight ways),
                    // tenths or hundredths of a degree: a full turn is the
                    // first of those its span fits in.
                    let turn = [360, 3600, 36000].first { wideSpan <= $0 } ?? wideSpan
                    let directions = angular ? turn : (span == 4 ? 4 : 8)
                    let minimum = angular ? field.rangeMin : (span == 4 || span == 8) ? field.logicalMin
                        : ((0...1).contains(field.logicalMin) ? field.logicalMin : 0)
                    hatsPerReport[r].append(.init(bitOffset: field.bitOffset,
                                                  bitSize: field.bitSize,
                                                  logicalMin: minimum,
                                                  directions: directions,
                                                  index: hatCount))
                    hatCount += 1
                }
            }
        }

        // Axes. Slots follow the rest of the app: 0/1 left stick, 2/3
        // right stick, 4/5 analog triggers (0...1), 6 and up extras.
        var candidates: [AxisCandidate] = []
        for (r, fields) in keptFields.enumerated() {
            for field in fields where isAxis(field) {
                candidates.append(AxisCandidate(field: field, reportIndex: r))
            }
        }
        candidates.sort { $0.order < $1.order }

        var slotOf: [Int: Int] = [:]   // candidate index -> axis slot
        var used = Set<Int>()
        func assign(_ c: Int, _ slot: Int) {
            slotOf[c] = slot
            used.insert(slot)
        }
        func isGD(_ c: Int, _ usage: Int) -> Bool {
            candidates[c].field.usagePage == 0x01 && candidates[c].field.usage == usage
        }
        let stickIdx = candidates.indices.filter {
            candidates[$0].field.usagePage == 0x01 && (0x30...0x35).contains(candidates[$0].field.usage)
        }
        let stickUsages = stickIdx.map { candidates[$0].field.usage }
        let hasDuplicateStickUsages = Set(stickUsages).count != stickUsages.count

        if hasDuplicateStickUsages {
            // Usages are unreliable (DragonRise lists X four times), so
            // take the first four in report order as the two sticks, the
            // way earlier versions did, and send the rest to extras.
            for (n, c) in stickIdx.prefix(4).enumerated() { assign(c, n) }
        } else {
            func first(_ usage: Int) -> Int? { stickIdx.first { isGD($0, usage) } }
            if let x = first(0x30) { assign(x, 0) }
            if let y = first(0x31) { assign(y, 1) }
            let z = first(0x32), rx = first(0x33), ry = first(0x34), rz = first(0x35)
            // Right stick: Rx/Ry when present. Z/Rz take it instead on
            // pads without Rx/Ry, and on DualShock 4 style pads where Z/Rz
            // come first and Rx/Ry are the analog triggers.
            var right: (Int, Int)? = nil
            if let z, let rz, let rx, let ry {
                right = max(z, rz) < min(rx, ry) ? (z, rz) : (rx, ry)
            } else if let rx, let ry {
                right = (rx, ry)
            } else if let z, let rz {
                right = (z, rz)
            }
            if let right {
                assign(right.0, 2)
                assign(right.1, 3)
            }
            // Leftover stick usages fill free stick slots in report
            // order (a flight stick's X, Y, Rz twist keeps Rz on 2).
            var leftovers: [Int] = []
            for c in stickIdx where slotOf[c] == nil {
                if let free = (0...3).first(where: { !used.contains($0) }) {
                    assign(c, free)
                } else {
                    leftovers.append(c)
                }
            }
            // A pair left over (Z and Rz, or Rx and Ry), when unsigned, is
            // the two analog triggers. A lone one is not: a combined trigger
            // axis or a throttle rests mid travel, and as a 0 to 1 trigger it
            // read half pulled at rest (LT held, Scan catching LT at once).
            // It goes to the extras below as an ordinary axis.
            let unsignedLeftovers = leftovers.filter { !candidates[$0].field.isSigned && !candidates[$0].field.isRelative }
            if unsignedLeftovers.count >= 2 {
                for c in unsignedLeftovers {
                    if let free = (4...5).first(where: { !used.contains($0) }) { assign(c, free) }
                }
            }
        }

        // Simulation page pedals: Brake on the left trigger, Accelerator
        // on the right, whichever trigger slot is free otherwise.
        for (usage, preferred) in [(0xC5, 4), (0xC4, 5)] {
            for c in candidates.indices where slotOf[c] == nil
                && candidates[c].field.usagePage == 0x02 && candidates[c].field.usage == usage {
                if !used.contains(preferred) {
                    assign(c, preferred)
                } else if let free = (4...5).first(where: { !used.contains($0) }) {
                    assign(c, free)
                }
            }
        }
        // Steering drives the left stick X when nothing else does.
        for c in candidates.indices where slotOf[c] == nil
            && candidates[c].field.usagePage == 0x02 && candidates[c].field.usage == 0xC8
            && !used.contains(0) {
            assign(c, 0)
        }
        // Sliders and dials were always read as analog triggers; keep
        // that while a trigger slot is free.
        // A centered (signed) one, or one that reports turns (relative), is
        // not a trigger: it rests mid travel and would read half pulled.
        for c in candidates.indices where slotOf[c] == nil
            && candidates[c].field.usagePage == 0x01
            && (candidates[c].field.usage == 0x36 || candidates[c].field.usage == 0x37)
            && !isCenteredSliderOrDial(candidates[c].field) && !candidates[c].field.isRelative {
            if let free = (4...5).first(where: { !used.contains($0) }) {
                assign(c, free)
            }
        }
        // Everything else lands after the real axes, in report order: the
        // usages read before 1.7 first, so their numbers stay, then the ones
        // read since (toe brakes, clutch, collective, aileron, the Game
        // Controls and velocity axes).
        var nextExtra = 6
        for pass in [true, false] {
            for c in candidates.indices where slotOf[c] == nil && isLegacyAxis(candidates[c].field) == pass {
                assign(c, nextExtra)
                nextExtra += 1
            }
        }
        // Then the axes of a report that repeats another's controls (port 2's
        // X and Y on a two-port adapter), after every axis numbered above.
        for (r, fields) in repeatedButtons.enumerated() {
            for field in fields.sorted(by: { $0.bitOffset < $1.bitOffset }) where isAxis(field) {
                candidates.append(AxisCandidate(field: field, reportIndex: r))
                assign(candidates.count - 1, nextExtra)
                nextExtra += 1
            }
        }

        var axesPerReport: [[HIDExtendedLayout.Axis]] = keptFields.map { _ in [] }
        for (c, candidate) in candidates.enumerated() {
            guard let slot = slotOf[c] else { continue }
            let f = candidate.field
            let isTrigger = (slot == 4 || slot == 5) && !f.isRelative
            // Mirror a trigger onto the LT/RT button slot only when the
            // device has no physical button there; a pad with 8+ buttons
            // lost its real buttons 6 and 7 to this before.
            // Not for a slider or dial with a signed range: one centered at
            // rest reads half way, and its mirror held LT down for good.
            let centeredDial = isCenteredSliderOrDial(f)
            let mirror = isTrigger && !centeredDial && buttonPageCount <= slot + 2 ? slot + 2 : nil
            axesPerReport[candidate.reportIndex].append(.init(
                bitOffset: f.bitOffset,
                bitSize: f.bitSize,
                logicalMin: f.rangeMin,
                logicalMax: f.rangeMax,
                isSigned: f.isSigned,
                usagePage: f.usagePage,
                usage: f.usage,
                index: slot,
                unipolar: isTrigger,
                digitalButton: mirror,
                relative: f.isRelative
            ))
        }

        // Buttons read since 1.7, numbered after every button read before so
        // presets made earlier keep theirs: one-bit Simulation and Game
        // Controls switches (a flight stick's trigger, landing gear, weapons
        // arm), Button page fields wider than a bit (a pressure button, or a
        // 0..1 button in a byte), and array inputs.
        // They are numbered once the triggers are placed, around the LT and
        // RT numbers a trigger is mirrored onto, so a row on those keeps
        // firing on the trigger.
        let mirrored = Set(axesPerReport.flatMap { $0.compactMap(\.digitalButton) })
        func nextButton() -> Int {
            while mirrored.contains(buttonCount) { buttonCount += 1 }
            defer { buttonCount += 1 }
            return buttonCount
        }
        for (r, fields) in keptFields.enumerated() {
            for field in fields.sorted(by: { $0.bitOffset < $1.bitOffset }) where isLaterButton(field) || isWideButton(field) {
                let rest = field.bitSize > 1 ? field.rangeMin + max(0, (field.rangeMax - field.rangeMin) / 16) : 0
                buttonsPerReport[r].append(.init(bitOffset: field.bitOffset, index: nextButton(),
                                                 bitSize: min(32, field.bitSize), pressAbove: rest))
            }
        }
        for (r, fields) in repeatedButtons.enumerated() {
            for field in fields.sorted(by: { $0.bitOffset < $1.bitOffset }) where !isHat(field) && !isAxis(field) {
                buttonsPerReport[r].append(.init(bitOffset: field.bitOffset, index: nextButton()))
            }
        }
        var arraysPerReport: [Int?: [HIDExtendedLayout.ButtonArray]] = [:]
        for key in arraysByReport.keys.sorted(by: { ($0 ?? -1) < ($1 ?? -1) }) {
            for array in arraysByReport[key] ?? [] where array.usagePage == 0x09 || array.usagePage == 0x0C {
                // Usage 0 is "no button pressed" (Button page) or unassigned
                // (Consumer): the value naming it is the resting state.
                let skip = array.usages.first == 0 ? 1 : 0
                let count = array.usages.count - skip
                guard count > 0 else { continue }
                // A run of numbers clear of the mirrored ones.
                while (buttonCount..<(buttonCount + count)).contains(where: mirrored.contains) { buttonCount += 1 }
                arraysPerReport[key, default: []].append(.init(
                    bitOffset: array.bitOffset, bitSize: array.bitSize, count: array.count,
                    logicalMin: array.logicalMin + skip, firstIndex: buttonCount,
                    buttons: count))
                buttonCount += count
            }
        }

        guard buttonCount > 0 || !candidates.isEmpty || hatCount > 0 else { return nil }
        // A report that carries only an array input still needs an entry.
        for key in arraysPerReport.keys where !keptKeys.contains(where: { $0 == key }) {
            keptKeys.append(key)
            buttonsPerReport.append([])
            axesPerReport.append([])
            hatsPerReport.append([])
        }

        var reports: [HIDExtendedLayout.Report] = []
        for (r, key) in keptKeys.enumerated() {
            reports.append(.init(
                reportID: key,
                payloadSize: ((cursorByReport[key] ?? 0) + 7) / 8,
                buttons: buttonsPerReport[r],
                axes: axesPerReport[r].sorted { $0.index < $1.index },
                hats: hatsPerReport[r],
                buttonArrays: arraysPerReport[key] ?? []
            ))
        }
        return HIDExtendedLayout(usesReportIDs: primaryKey != nil, reports: reports)
    }

    /// A Slider or Dial whose range is centered on zero (a trim wheel, a
    /// jog or shuttle ring): it rests mid travel, so it is no analog trigger.
    private static func isCenteredSliderOrDial(_ f: Field) -> Bool {
        f.isSigned && f.rangeMin < 0 && f.usagePage == 0x01 && (f.usage == 0x36 || f.usage == 0x37)
    }

    private static func isHat(_ f: Field) -> Bool {
        // 4-bit and 8-bit hats (0-7/8 in the low nibble, padding above), and
        // since 1.7 any width from 2 to 16 bits: a 3-bit 8-way hat, or a hat
        // that reports its angle in a 9 or 16 bit field.
        f.usagePage == 0x01 && f.usage == 0x39 && (2...16).contains(f.bitSize)
    }

    /// The hat widths read before 1.7, numbered first.
    private static func isLegacyHat(_ f: Field) -> Bool {
        isHat(f) && (f.bitSize == 4 || f.bitSize == 8)
    }

    private static func isAxis(_ f: Field) -> Bool {
        guard f.bitSize >= 2 && f.bitSize <= 32 else { return false }
        if isLegacyAxis(f) { return true }
        switch f.usagePage {
        // Velocity (Vx to Vbrz), sent by some 6-axis devices.
        case 0x01: return (0x40...0x45).contains(f.usage)
        // Every Simulation Controls axis: aileron, elevator, trims, toe
        // brakes, clutch, shifter, collective, flaps and the rest.
        case 0x02: return (0xB0...0xCF).contains(f.usage)
        // Game Controls: turn, pitch, roll, move and lean axes.
        case 0x05: return (0x21...0x2A).contains(f.usage)
        default: return false
        }
    }

    /// The axis usages read before 1.7, numbered first among the extras.
    private static func isLegacyAxis(_ f: Field) -> Bool {
        guard f.bitSize >= 2 && f.bitSize <= 32 else { return false }
        switch f.usagePage {
        case 0x01: return (0x30...0x38).contains(f.usage)
        case 0x02: return [0xBA, 0xBB, 0xC4, 0xC5, 0xC8].contains(f.usage)
        default: return false
        }
    }

    private static func isControl(_ f: Field) -> Bool {
        (f.usagePage == 0x09 && f.bitSize == 1) || isHat(f) || isAxis(f) || isExtraButton(f)
            || isLaterButton(f) || isWideButton(f)
    }

    /// One-bit switches on the Simulation Controls and Game Controls pages
    /// (a flight stick's trigger, weapons arm, landing gear, a gun's trigger).
    private static func isLaterButton(_ f: Field) -> Bool {
        f.bitSize == 1 && (f.usagePage == 0x02 || f.usagePage == 0x05)
    }

    /// A Button page field wider than one bit: a pressure button, or a
    /// button sent as a 0 or 1 in a whole byte.
    private static func isWideButton(_ f: Field) -> Bool {
        f.usagePage == 0x09 && f.bitSize >= 2 && f.bitSize <= 16 && f.rangeMax > f.rangeMin
    }

    /// One-bit controls a pad can send outside the Button page: Home, Back
    /// and Menu on the Consumer page (Android and HID mode pads), and Start,
    /// Select, System Main Menu and D-pad bits on Generic Desktop. The SDL
    /// path already read them; they are numbered after every Button page
    /// button, so pads that worked before keep their numbers.
    private static func isExtraButton(_ f: Field) -> Bool {
        guard f.bitSize == 1 else { return false }
        if f.usagePage == 0x0C { return true }
        return f.usagePage == 0x01 && [0x3D, 0x3E, 0x85, 0x90, 0x91, 0x92, 0x93].contains(f.usage)
    }

    /// Scored with the controls read before 1.7 only, so the report chosen
    /// as primary, and every number that follows from it, stays the same.
    private static func controlScore(_ fields: [Field]) -> Int {
        var score = 0
        for f in fields {
            if f.usagePage == 0x09 && f.bitSize == 1 { score += 1 }
            else if isLegacyAxis(f) { score += 2 }
            else if isLegacyHat(f) { score += 2 }
        }
        return score
    }

    // MARK: - Parse state

    /// Global items, saved and restored as one unit by PUSH / POP.
    private struct GlobalState {
        var usagePage: Int = 0
        var logicalMin: Int = 0
        var logicalMax: Int = 0
        var logicalMaxUnsigned: Int = 0
        var reportSize: Int = 0
        var reportCount: Int = 0
        var reportID: Int? = nil
    }

    private struct ParseState {
        var global = GlobalState()
        var usages: [Usage] = []
        var usageMin = Usage(page: nil, id: 0)
        var usageMax = Usage(page: nil, id: 0)
        var hasUsageMin = false
        var hasUsageMax = false

        /// Usage assigned to the nth entry in a multi-count INPUT item.
        /// HID lets you either list explicit usages (one per entry) or
        /// give a usage range; explicit usages win, and the last one
        /// repeats. A range stops at USAGE_MAXIMUM (HID 1.11 6.2.2.8):
        /// entries past it reuse the maximum instead of inventing usages.
        func usage(forIndex n: Int) -> Usage {
            if !usages.isEmpty {
                return usages[min(n, usages.count - 1)]
            }
            if hasUsageMin || hasUsageMax {
                let upper = hasUsageMax ? max(usageMax.id, usageMin.id) : Int.max
                return Usage(page: usageMin.page ?? usageMax.page,
                             id: min(usageMin.id + n, upper))
            }
            return Usage(page: nil, id: 0)
        }

        /// The usages an array item's values stand for, from the logical
        /// minimum up: a listed set or a usage range. Nil when the item is
        /// not one of buttons, or names more than 128 of them (a keyboard's
        /// or the whole Consumer page's, which are not a controller's).
        func arrayUsages(logicalMin: Int, logicalMax: Int) -> (page: Int?, ids: [Int])? {
            let span = logicalMax - logicalMin + 1
            guard span >= 1, span <= 128 else { return nil }
            var ids: [Int] = []
            var page: Int? = nil
            if !usages.isEmpty {
                ids = usages.map(\.id)
                page = usages.first?.page
            } else if hasUsageMin || hasUsageMax {
                let lo = usageMin.id, hi = hasUsageMax ? usageMax.id : usageMin.id + span - 1
                guard hi >= lo, hi - lo < 128 else { return nil }
                ids = Array(lo...hi)
                page = usageMin.page ?? usageMax.page
            } else {
                return nil
            }
            return (page, Array(ids.prefix(span)))
        }

        mutating func clearLocals() {
            usages.removeAll(keepingCapacity: true)
            usageMin = Usage(page: nil, id: 0)
            usageMax = Usage(page: nil, id: 0)
            hasUsageMin = false
            hasUsageMax = false
        }
    }
}

// MARK: - Extended layout

/// Everything the decoder needs for a generic HID device: per-field bit
/// offset, bit size, and logical range, every hat, and every input report
/// that carries controls. `GenericLayout` only has room for byte-aligned
/// axes and one hat, so this rides alongside it in the registry.
struct HIDExtendedLayout: Equatable {

    struct Button: Equatable {
        var bitOffset: Int
        var index: Int
        var bitSize: Int = 1      // A pressure button reads its whole field
        var pressAbove: Int = 0   // Pressed when the field reads more than this
        var forcesAxis: Int? = nil // Pressed, this axis reads 1 (a stick's digital L2 bit over an analog byte it leaves at 0)
    }

    struct Axis: Equatable {
        var bitOffset: Int
        var bitSize: Int
        var logicalMin: Int
        var logicalMax: Int
        var isSigned: Bool        // Two's complement field (logical minimum below zero)
        var usagePage: Int
        var usage: Int
        var index: Int            // Slot in ControllerState.axes
        var unipolar: Bool        // 0...1 (trigger slots) instead of -1...1
        var digitalButton: Int?   // Button slot mirrored at > 0.12, only where no physical button exists
        var inverted: Bool = false // Flip the value (a GameControllerDB "~" axis, or a "-" half axis)
        var relative: Bool = false // Reports a change since the last report (a knob), not a position
        var wrapCounter: Bool = false // A position counter that wraps (a jog wheel): the pad takes the delta from the last report
    }

    /// A D-pad direction sent as its own button, folded into a hat. Some
    /// pads (USB SNES and NES style ones) send the D-pad as two axes
    /// instead: `axisHalf` then names the field and which half of it is
    /// this direction.
    struct DpadButton: Equatable {
        enum Direction: Equatable { case up, down, left, right }
        var bitOffset: Int
        var direction: Direction
        var hatIndex: Int
        var axisHalf: AxisHalf? = nil
        var bitSize: Int = 1      // A pressure button reads its whole field
        var pressAbove: Int = 0   // Pressed when the field reads more than this
    }

    /// One half of an axis read as a D-pad direction.
    struct AxisHalf: Equatable {
        var bitSize: Int
        var logicalMin: Int
        var logicalMax: Int
        var isSigned: Bool
        var positive: Bool        // The direction is pressed on the high half
    }

    struct Hat: Equatable {
        var bitOffset: Int
        var bitSize: Int
        var logicalMin: Int
        var directions: Int       // 8, or 4 for a 0..3 hat; above 16, an angle over that many steps
        var index: Int            // Slot in ControllerState.hats
    }

    /// An array input: each of `count` entries holds the number of a
    /// button that is down (from logicalMin), or a value outside the
    /// range for none. Its buttons are firstIndex up.
    struct ButtonArray: Equatable {
        var bitOffset: Int
        var bitSize: Int
        var count: Int
        var logicalMin: Int
        var firstIndex: Int
        var buttons: Int
    }

    struct Report: Equatable {
        var reportID: Int?        // nil: no ID byte (or, for a legacy layout, any ID)
        var payloadSize: Int      // Bytes after the ID byte
        var buttons: [Button]
        var axes: [Axis]
        var hats: [Hat]
        var dpadButtons: [DpadButton] = []
        var buttonArrays: [ButtonArray] = []
    }

    var usesReportIDs: Bool
    var reports: [Report]
    /// A hand-written layout's report must arrive whole: its length tells
    /// one report format from another. A descriptor plan reads each field
    /// that arrived, so a pad that leaves off trailing vendor bytes works.
    var requiresFullReport = false

    /// Every button number the plan can set: bit buttons and the buttons of
    /// array inputs.
    var buttonIndices: [Int] {
        reports.flatMap { r in
            r.buttons.map(\.index) + r.buttonArrays.flatMap { $0.firstIndex..<($0.firstIndex + $0.buttons) }
        }
    }

    /// The axis slots that report turns of a knob, not a position.
    var relativeAxisSlots: [Int] {
        Array(Set(reports.flatMap { $0.axes.filter(\.relative).map(\.index) })).sorted()
    }

    /// The report entry that decodes a report carrying this ID.
    func report(forID id: Int) -> Report? {
        reports.first { $0.reportID == id } ?? reports.first { $0.reportID == nil }
    }

    /// Projection into the legacy struct, for the profile, the scaffold's
    /// capability counts, and the self-test. It describes the primary
    /// report; the decoder reads the extended layout itself.
    var legacyLayout: ControllerProfile.GenericLayout {
        let primary = reports.first
        let allAxes = reports.flatMap(\.axes)
        let sticks = allAxes.filter { $0.index < 4 }.sorted { $0.index < $1.index }
        let triggers = allAxes.filter { $0.index == 4 || $0.index == 5 }.sorted { $0.index < $1.index }
        let firstHat = reports.flatMap(\.hats).first
        return ControllerProfile.GenericLayout(
            buttonBitOffsets: reports.flatMap(\.buttons).sorted { $0.index < $1.index }.map(\.bitOffset),
            axisByteOffsets: sticks.map { $0.bitOffset / 8 },
            axisByteWidths: sticks.map { ($0.bitSize + 7) / 8 },
            axisIsSignedFlags: sticks.map(\.isSigned),
            axisUsages: sticks.map { $0.usagePage == 0x01 ? $0.usage : ($0.usagePage << 16) | $0.usage },
            hatByteOffset: firstHat.map { $0.bitOffset / 8 },
            triggerByteOffsets: triggers.map { $0.bitOffset / 8 },
            reportSize: primary?.payloadSize ?? 0,
            hasReportID: usesReportIDs,
            hatBitOffset: firstHat?.bitOffset,
            hatLogicalMin: firstHat?.logicalMin ?? 0,
            reportID: usesReportIDs ? primary?.reportID : nil
        )
    }

    /// Plan for a `GenericLayout` the parser did not produce (the raw
    /// bit-field fallback, or any hand-built layout): byte-aligned axes
    /// at their full width, triggers on the free trigger slots, one hat.
    init(legacy layout: ControllerProfile.GenericLayout) {
        var axes: [Axis] = []
        var used = Set<Int>()
        for (i, byte) in layout.axisByteOffsets.enumerated() {
            let width = i < layout.axisByteWidths.count ? layout.axisByteWidths[i] : 1
            let signed = i < layout.axisIsSignedFlags.count ? layout.axisIsSignedFlags[i] : false
            let bits = max(1, min(4, width)) * 8
            let usage = i < layout.axisUsages.count ? layout.axisUsages[i] : 0
            axes.append(Axis(bitOffset: byte * 8, bitSize: bits,
                             logicalMin: signed ? -(1 << (bits - 1)) : 0,
                             logicalMax: signed ? (1 << (bits - 1)) - 1 : (1 << bits) - 1,
                             isSigned: signed, usagePage: usage > 0xFFFF ? usage >> 16 : 0x01,
                             usage: usage & 0xFFFF, index: i, unipolar: i == 4 || i == 5,
                             digitalButton: nil))
            used.insert(i)
        }
        var nextExtra = max(6, layout.axisByteOffsets.count)
        for byte in layout.triggerByteOffsets {
            let slot: Int
            if let free = (4...5).first(where: { !used.contains($0) }) {
                slot = free
            } else {
                slot = nextExtra
                nextExtra += 1
            }
            used.insert(slot)
            let isTrigger = slot == 4 || slot == 5
            axes.append(Axis(bitOffset: byte * 8, bitSize: 8, logicalMin: 0, logicalMax: 255,
                             isSigned: false, usagePage: 0x01, usage: 0x36, index: slot,
                             unipolar: isTrigger,
                             digitalButton: isTrigger && layout.buttonBitOffsets.count <= slot + 2 ? slot + 2 : nil))
        }
        var hats: [Hat] = []
        if let bit = layout.hatBitOffset ?? layout.hatByteOffset.map({ $0 * 8 }) {
            hats.append(Hat(bitOffset: bit, bitSize: 4, logicalMin: layout.hatLogicalMin,
                            directions: 8, index: 0))
        }
        let report = Report(
            reportID: layout.hasReportID ? layout.reportID : nil,
            payloadSize: layout.reportSize,
            buttons: layout.buttonBitOffsets.enumerated().map { Button(bitOffset: $0.element, index: $0.offset) },
            axes: axes,
            hats: hats
        )
        self.init(usesReportIDs: layout.hasReportID, reports: [report])
        requiresFullReport = true
    }

    init(usesReportIDs: Bool, reports: [Report]) {
        self.usesReportIDs = usesReportIDs
        self.reports = reports
    }
}

/// Plans synthesized from hand-coded profiles, which carry no parsed
/// `extended`, cached by the layout's contents so a report does not
/// rebuild one. Parsed layouts never come here: their plan rides on the
/// layout itself. Read from the HID report callback, hence the lock.
enum HIDExtendedLayoutRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [Key: HIDExtendedLayout] = [:]

    /// The plan for `layout`: its own, or one synthesized (and cached)
    /// from the legacy fields.
    static func extended(for layout: ControllerProfile.GenericLayout) -> HIDExtendedLayout {
        if let own = layout.extended { return own }
        let key = Key(layout)
        lock.lock()
        defer { lock.unlock() }
        if let found = table[key] { return found }
        let synthesized = HIDExtendedLayout(legacy: layout)
        table[key] = synthesized
        return synthesized
    }

    private struct Key: Hashable {
        let buttons: [Int]
        let axisBytes: [Int]
        let axisWidths: [Int]
        let axisSigned: [Bool]
        let axisUsages: [Int]
        let hatByte: Int?
        let triggers: [Int]
        let reportSize: Int
        let hasReportID: Bool
        let hatBit: Int?
        let hatMin: Int
        let reportID: Int?

        init(_ l: ControllerProfile.GenericLayout) {
            buttons = l.buttonBitOffsets
            axisBytes = l.axisByteOffsets
            axisWidths = l.axisByteWidths
            axisSigned = l.axisIsSignedFlags
            axisUsages = l.axisUsages
            hatByte = l.hatByteOffset
            triggers = l.triggerByteOffsets
            reportSize = l.reportSize
            hasReportID = l.hasReportID
            hatBit = l.hatBitOffset
            hatMin = l.hatLogicalMin
            reportID = l.reportID
        }
    }
}
