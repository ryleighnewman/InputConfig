import SwiftUI

/// Flat macOS keyboard for the Live Visualizer, drawn in the shape of the
/// keyboard in front of the user (ANSI, ISO or JIS) with each key labeled
/// with what it types under their input source, and, on a full-size
/// keyboard or when a row uses them, the navigation keys and number pad of
/// Apple's Magic Keyboard with Numeric Keypad beside it. Each key tile
/// lights up green when pressed (via `ExternalInputDeviceService.rawActiveInputs`),
/// stays at full opacity if a binding targets it, and dims when it has no
/// binding in this slot.
///
/// Every row of the main block is 14.5 keys wide and a key's width counts
/// the gaps it spans, so the columns line up from row to row.
struct KeyboardDiagramView: View {
    /// HID keycodes (from `InputEvent.index` for `.extKey`) that are
    /// bound by this slot in the preset. Drives the "in color vs
    /// dimmed" treatment.
    let boundKeyCodes: Set<Int>
    /// HID keycodes currently pressed - drawn green on top of the base.
    let pressedKeyCodes: Set<Int>
    /// Makes a bound key clickable: the host wraps its tile in its
    /// inspector (the popover listing the key's rows, each a way to the
    /// editor) for the tile's codes, under the key's name. Keys no row uses
    /// stay as they are. nil leaves the diagram read-only.
    var inspect: ((_ codes: [Int], _ name: String, _ tile: AnyView) -> AnyView)? = nil

    @ObservedObject private var layout = KeyboardLayoutService.shared
    @ObservedObject private var registry = HIDDeviceRegistry.shared
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.appHighContrast) private var appHighContrast
    /// A lit key's label: white on the green as designed, black (about
    /// 8:1 against 2.6:1) when more contrast is asked for.
    private var pressedLabel: Color { colorSchemeContrast == .increased || appHighContrast ? .black : .white }

    /// A tile wrapped for clicking when a row binds any of its codes. With
    /// clicking on, the other tiles are hidden from VoiceOver, so it moves
    /// between the bound keys alone.
    @ViewBuilder
    private func clickable<Tile: View>(codes: [Int], @ViewBuilder _ tile: () -> Tile) -> some View {
        if let inspect, codes.contains(where: { boundKeyCodes.contains($0) }) {
            let code = codes.first(where: boundKeyCodes.contains) ?? codes.first
            let name = code.map { KeyCodeMap.name(for: $0) } ?? String(localized: "Key")
            inspect(codes, name, AnyView(tile().accessibilityLabel(HotKeySpec.spokenKey(name))))
        } else {
            tile().accessibilityHidden(inspect != nil)
        }
    }

    // MARK: Rows

    /// The plain F keys, what the top row sends with fn held, in their own
    /// row above the glyph row and in the same columns.
    private static let fRow: [Key] = [
        .spacer(1.5),
        .key(58, "F1", 1.0), .key(59, "F2", 1.0), .key(60, "F3", 1.0), .key(61, "F4", 1.0),
        .key(62, "F5", 1.0), .key(63, "F6", 1.0), .key(64, "F7", 1.0), .key(65, "F8", 1.0),
        .key(66, "F9", 1.0), .key(67, "F10", 1.0), .key(68, "F11", 1.0), .key(69, "F12", 1.0),
        .spacer(1.0)
    ]

    /// The top row the way a Mac keyboard prints it: a wide esc, the twelve
    /// special-function glyphs, and the Touch ID key's slot at the end.
    private static let glyphRow: [Key] = [
        .key(41, "esc", 1.5),
        .symbol([71], "sun.min", 1.0),            // brightness down
        .symbol([72], "sun.max", 1.0),            // brightness up
        .symbol([304], "rectangle.3.group", 1.0), // Mission Control
        .symbol([KeyCodeMap.spotlightKeyCode], "magnifyingglass", 1.0),
        .symbol([KeyCodeMap.dictationKeyCode], "mic", 1.0),
        .symbol([KeyCodeMap.focusKeyCode], "moon", 1.0),
        .symbol([307], "backward.fill", 1.0),      // previous track
        .symbol([308], "playpause.fill", 1.0),     // play / pause
        .symbol([309], "forward.fill", 1.0),       // next track
        .symbol([310], "speaker.slash.fill", 1.0), // mute
        .symbol([312], "speaker.wave.1.fill", 1.0),// volume down
        .symbol([311], "speaker.wave.3.fill", 1.0),// volume up
        .blank(1.0)                                // Touch ID
    ]

    private static let letterRowTop: [Key] = [20, 26, 8, 21, 23, 28, 24, 12, 18, 19].map { .key($0, "", 1.0) }
    private static let letterRowHome: [Key] = [4, 22, 7, 9, 10, 11, 13, 14, 15].map { .key($0, "", 1.0) }
    private static let letterRowBottom: [Key] = [29, 27, 6, 25, 5, 17, 16].map { .key($0, "", 1.0) }
    private static let digits: [Key] = [30, 31, 32, 33, 34, 35, 36, 37, 38, 39].map { .key($0, "", 1.0) }

    /// The main block for a shape. Labels left empty are filled from the
    /// input source; the rest are the keys' own glyphs. With the extended
    /// keys shown the arrows move to their own cluster, as on a full-size
    /// keyboard.
    static func mainRows(_ shape: KeyboardLayoutService.Shape, extended: Bool) -> [[Key]] {
        let bottomRow: [Key] = extended
            ? [.key(224, "⌃", 1.5), .key(226, "⌥", 1.25), .key(227, "⌘", 1.5), .key(44, "space", 6.5),
               .key(231, "⌘", 1.5), .key(230, "⌥", 1.25), .key(228, "⌃", 1.0)]
            : [.symbol([KeyCodeMap.globeKeyCode, KeyCodeMap.globeFnCode], "globe", 1.0),
               .key(224, "⌃", 1.0), .key(226, "⌥", 1.0), .key(227, "⌘", 1.25), .key(44, "space", 5.0),
               .key(231, "⌘", 1.25), .key(230, "⌥", 1.0),
               .key(80, "◀", 1.0), .stack(82, 81, 1.0), .key(79, "▶", 1.0)]
        switch shape {
        case .ansi:
            return [
                fRow, glyphRow,
                [.key(53, "`", 1.0)] + digits + [.key(45, "-", 1.0), .key(46, "=", 1.0), .key(42, "⌫", 1.5)],
                [.key(43, "⇥", 1.5)] + letterRowTop + [.key(47, "[", 1.0), .key(48, "]", 1.0), .key(49, "\\", 1.0)],
                [.key(57, "⇪", 1.75)] + letterRowHome + [.key(51, ";", 1.0), .key(52, "'", 1.0), .key(40, "↩", 1.75)],
                [.key(225, "⇧", 2.25)] + letterRowBottom + [.key(54, ",", 1.0), .key(55, ".", 1.0), .key(56, "/", 1.0), .key(229, "⇧", 2.25)],
                bottomRow
            ]
        case .iso:
            // Apple ISO: the key top left is the section key (vk 10), the
            // one left of Z is the key ANSI has top left (vk 50), the key
            // left of Return is backslash's (vk 42), and Return spans two
            // rows, drawn as its top and its foot.
            return [
                fRow, glyphRow,
                [.key(100, "§", 1.0)] + digits + [.key(45, "-", 1.0), .key(46, "=", 1.0), .key(42, "⌫", 1.5)],
                [.key(43, "⇥", 1.5)] + letterRowTop + [.key(47, "[", 1.0), .key(48, "]", 1.0), .key(40, "↩", 1.0)],
                [.key(57, "⇪", 1.75)] + letterRowHome + [.key(51, ";", 1.0), .key(52, "'", 1.0),
                                                         .keys([49, 50], "\\", 1.0), .foot(40, 0.75)],
                [.key(225, "⇧", 1.25), .key(53, "`", 1.0)] + letterRowBottom
                    + [.key(54, ",", 1.0), .key(55, ".", 1.0), .key(56, "/", 1.0), .key(229, "⇧", 2.25)],
                bottomRow
            ]
        case .jis:
            // Apple JIS: no key left of 1, the Yen key before delete,
            // Control where Caps Lock is elsewhere, the underscore key
            // before right Shift, Eisu and Kana either side of the space bar.
            let jisBottom: [Key] = extended
                ? [.key(57, "⇪", 1.25), .key(226, "⌥", 1.25), .key(227, "⌘", 1.5), .key(145, "英数", 1.25),
                   .key(44, "space", 4.5), .key(144, "かな", 1.25), .key(231, "⌘", 1.5), .key(230, "⌥", 2.0)]
                : [.symbol([KeyCodeMap.globeKeyCode, KeyCodeMap.globeFnCode], "globe", 1.0),
                   .key(57, "⇪", 1.0), .key(226, "⌥", 1.0), .key(227, "⌘", 1.25), .key(145, "英数", 1.25),
                   .key(44, "space", 3.5), .key(144, "かな", 1.25), .key(231, "⌘", 1.25),
                   .key(80, "◀", 1.0), .stack(82, 81, 1.0), .key(79, "▶", 1.0)]
            return [
                fRow, glyphRow,
                digits + [.key(45, "-", 1.0), .key(46, "^", 1.0), .key(137, "¥", 1.0), .key(42, "⌫", 1.5)],
                [.key(43, "⇥", 1.5)] + letterRowTop + [.key(47, "@", 1.0), .key(48, "[", 1.0), .key(40, "↩", 1.0)],
                [.key(224, "⌃", 1.75)] + letterRowHome + [.key(51, ";", 1.0), .key(52, ":", 1.0),
                                                          .keys([49, 50], "]", 1.0), .foot(40, 0.75)],
                [.key(225, "⇧", 2.25)] + letterRowBottom
                    + [.key(54, ",", 1.0), .key(55, ".", 1.0), .key(56, "/", 1.0), .key(135, "_", 1.0), .key(229, "⇧", 1.25)],
                jisBottom
            ]
        }
    }

    /// The navigation keys and number pad of a full-size Apple keyboard, one
    /// row for each row of the main block so they line up: F13 to F19 over
    /// them, fn, Home, Page Up, Forward Delete, End and Page Down, the
    /// inverted-T arrows, and the keypad with its tall Enter.
    /// The extended block for a shape: a JIS keypad has a comma beside 0.
    static func extendedRows(_ shape: KeyboardLayoutService.Shape) -> [[Key]] {
        guard shape == .jis else { return extendedRows }
        var rows = extendedRows
        rows[6] = [.key(80, "◀", 1.0), .key(81, "▼", 1.0), .key(79, "▶", 1.0), .spacer(0.5),
                   .key(98, "0", 1.0), .key(133, ",", 1.0), .key(99, ".", 1.0), .foot(88, 1.0)]
        return rows
    }

    static let extendedRows: [[Key]] = [
        [.key(104, "F13", 1.0), .key(105, "F14", 1.0), .key(106, "F15", 1.0), .spacer(0.5),
         .key(107, "F16", 1.0), .key(108, "F17", 1.0), .key(109, "F18", 1.0), .key(110, "F19", 1.0)],
        [.spacer(7.5)],
        [.symbol([KeyCodeMap.globeFnCode, KeyCodeMap.globeKeyCode, 73], "globe", 1.0), .key(74, "↖", 1.0), .key(75, "⇞", 1.0), .spacer(0.5),
         .key(83, "⌧", 1.0), .key(103, "=", 1.0), .key(84, "/", 1.0), .key(85, "*", 1.0)],
        [.key(76, "⌦", 1.0), .key(77, "↘", 1.0), .key(78, "⇟", 1.0), .spacer(0.5),
         .key(95, "7", 1.0), .key(96, "8", 1.0), .key(97, "9", 1.0), .key(86, "-", 1.0)],
        [.spacer(3.0), .spacer(0.5),
         .key(92, "4", 1.0), .key(93, "5", 1.0), .key(94, "6", 1.0), .key(87, "+", 1.0)],
        [.spacer(1.0), .key(82, "▲", 1.0), .spacer(1.0), .spacer(0.5),
         .key(89, "1", 1.0), .key(90, "2", 1.0), .key(91, "3", 1.0), .key(88, "⌤", 1.0)],
        [.key(80, "◀", 1.0), .key(81, "▼", 1.0), .key(79, "▶", 1.0), .spacer(0.5),
         .key(98, "0", 2.0), .key(99, ".", 1.0), .foot(88, 1.0)]
    ]

    /// Codes that live in the extended block. A row using one shows it.
    private static let extendedCodes: Set<Int> = Set(104...110).union(73...78).union(83...99).union([103, 133])

    /// Whether to draw the navigation keys and number pad.
    private var showsExtended: Bool {
        switch layout.extendedKeys {
        case .always: return true
        case .never: return false
        case .automatic:
            if boundKeyCodes.contains(where: Self.extendedCodes.contains) { return true }
            // A full-size keyboard connected: Apple's Magic Keyboard with
            // Numeric Keypad, or another keyboard naming a number pad. Only
            // keyboards count; a gaming keypad or a gamepad named
            // "Extended" has no number pad.
            return registry.entries.contains { e in
                let n = e.name.lowercased()
                return e.kinds.contains(.keyboard) && (n.contains("numeric keypad") || n.contains("number pad")
                    || n.contains("numpad") || n.contains("extended keyboard"))
            }
        }
    }

    // A drawing of real hardware: never mirrored for right-to-left languages.
    var body: some View { drawing.environment(\.layoutDirection, .leftToRight) }

    @ViewBuilder private var drawing: some View {
        let extended = showsExtended
        HStack(alignment: .top, spacing: gap * 4) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(Array(Self.mainRows(layout.shape, extended: extended).enumerated()), id: \.offset) { _, row in
                    keyRow(row)
                }
            }
            if extended {
                VStack(alignment: .leading, spacing: gap) {
                    let rows = Self.extendedRows(layout.shape)
                    ForEach(rows.indices, id: \.self) { idx in
                        keyRow(rows[idx])
                    }
                }
            }
        }
        // The tiles are drawings, so VoiceOver read nothing here. One
        // element says which keys are held and which ones this slot binds,
        // holding the bound keys as buttons when they can be clicked.
        .accessibilityElement(children: inspect != nil && !boundKeyCodes.isEmpty ? .contain : .ignore)
        .accessibilityLabel(String(localized: "Keyboard"))
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        func names(_ codes: Set<Int>) -> String {
            // Marks by name: VoiceOver drops a lone "," or "-".
            codes.sorted().map { HotKeySpec.spokenKey(KeyCodeMap.name(for: $0)) }.joined(separator: ", ")
        }
        let pressed = pressedKeyCodes.isEmpty ? String(localized: "No keys pressed")
                                              : String(localized: "Pressed: \(names(pressedKeyCodes))")
        let bound = boundKeyCodes.isEmpty ? String(localized: "no keys bound")
                                          : String(localized: "bound: \(names(boundKeyCodes))")
        return "\(pressed); \(bound)"
    }

    @ViewBuilder
    private func keyRow(_ keys: [Key]) -> some View {
        HStack(spacing: gap) {
            ForEach(keys.indices, id: \.self) { idx in
                tileFor(keys[idx])
            }
        }
    }

    /// What a key shows: what it types under the layout for a key that types
    /// a character, else its own glyph.
    private func label(_ hid: Int, _ fallback: String) -> String {
        if let vk = KeyCodeMap.hidToVirtualKeyCode[hid], KeyboardLayoutService.printableKeys.contains(vk),
           let typed = layout.labels[vk] {
            return typed
        }
        return fallback
    }

    @ViewBuilder
    private func tileFor(_ key: Key) -> some View {
        switch key {
        case .spacer(let mult):
            Color.clear
                .frame(width: width(mult), height: keyUnit)
        case .blank(let mult):
            // A key that is there but is not an input (Touch ID).
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.75)
                .frame(width: width(mult), height: keyUnit)
        case .stack(let upHid, let downHid, let mult):
            // Two half-height keys in one column: the up and down arrows.
            VStack(spacing: 2) {
                halfTile(hid: upHid, label: "▲", mult: mult)
                halfTile(hid: downHid, label: "▼", mult: mult)
            }
            .frame(width: width(mult), height: keyUnit)
        case .key(let hid, let fallback, let mult):
            keyTile(codes: [hid], mult: mult) {
                faceText(label(hid, fallback), pressed: pressedKeyCodes.contains(hid))
            }
        case .keys(let codes, let fallback, let mult):
            keyTile(codes: codes, mult: mult) {
                faceText(label(codes[0], fallback), pressed: codes.contains { pressedKeyCodes.contains($0) })
            }
        case .foot(let hid, let mult):
            // The second part of a key drawn as two tiles: it lights with the
            // key, while the first part alone opens the key's rows.
            footTile(hid: hid, mult: mult)
        case .symbol(let codes, let name, let mult):
            keyTile(codes: codes, mult: mult) {
                Image(systemName: name)
                    .font(.system(size: 9, weight: .medium))
            }
        }
    }

    private func faceText(_ text: String, pressed: Bool) -> some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: pressed ? .semibold : .regular))
            .padding(.horizontal, 2)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private func footTile(hid: Int, mult: Double) -> some View {
        let pressed = pressedKeyCodes.contains(hid)
        let bound = boundKeyCodes.contains(hid)
        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(pressed ? Color.green.opacity(0.85) : Color.secondary.opacity(bound ? 0.22 : 0.08))
            RoundedRectangle(cornerRadius: 4)
                .stroke(pressed ? Color.green : Color.secondary.opacity(bound ? 0.55 : 0.2), lineWidth: pressed ? 1.5 : 0.75)
        }
        .frame(width: width(mult), height: keyUnit)
        .accessibilityHidden(true)
    }

    private func halfTile(hid: Int, label: String, mult: Double) -> some View {
        let pressed = pressedKeyCodes.contains(hid)
        let bound = boundKeyCodes.contains(hid)
        return clickable(codes: [hid]) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(pressed ? Color.green.opacity(0.85) : Color.secondary.opacity(bound ? 0.22 : 0.08))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(pressed ? Color.green : Color.secondary.opacity(bound ? 0.55 : 0.2), lineWidth: pressed ? 1.5 : 0.75)
                Text(verbatim: label)
                    .font(.system(size: 6, weight: pressed ? .semibold : .regular))
                    .foregroundStyle(pressed ? pressedLabel : (bound ? Color.primary : Color.secondary))
            }
            .frame(width: width(mult), height: (keyUnit - 2) / 2)
        }
    }

    /// One tile. Lit when any of its codes is down, in full contrast when
    /// any of them is bound.
    @ViewBuilder
    private func keyTile<Face: View>(codes: [Int], mult: Double, @ViewBuilder face: () -> Face) -> some View {
        let pressed = codes.contains { pressedKeyCodes.contains($0) }
        let bound = codes.contains { boundKeyCodes.contains($0) }
        clickable(codes: codes) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(pressed ? Color.green.opacity(0.85)
                                   : Color.secondary.opacity(bound ? 0.22 : 0.08))
                RoundedRectangle(cornerRadius: 4)
                    .stroke(pressed ? Color.green
                                    : Color.secondary.opacity(bound ? 0.55 : 0.2),
                            lineWidth: pressed ? 1.5 : 0.75)
                face()
                    .foregroundStyle(pressed ? pressedLabel
                                              : (bound ? Color.primary : Color.secondary))
            }
            .frame(width: width(mult), height: keyUnit)
        }
    }

    /// Size of a single key tile. Picked so the full keyboard fits in
    /// the visualizer column without horizontal scrolling.
    private let keyUnit: CGFloat = 22
    /// The space between tiles.
    private let gap: CGFloat = 3

    /// A key `mult` keys wide also covers the gaps between those keys, so
    /// every row of the same width ends in the same place.
    private func width(_ mult: Double) -> CGFloat {
        CGFloat(mult) * (keyUnit + gap) - gap
    }

    /// How many keys wide a row is.
    static func units(_ row: [Key]) -> Double { row.reduce(0) { $0 + $1.units } }

    enum Key {
        /// A key by HID code. An empty label is filled from the input source.
        case key(Int, String, Double)
        /// One key that arrives as any of several codes (the ISO key left of
        /// Return is backslash's key to macOS), labeled from the first.
        case keys([Int], String, Double)
        /// A tile drawn as an SF Symbol that lights for any of its codes.
        case symbol([Int], String, Double)
        /// A key drawn but never lit, for one that sends no input.
        case blank(Double)
        /// Two half-height keys stacked in one column (up over down).
        case stack(Int, Int, Double)
        /// The second tile of a key drawn as two (ISO and JIS Return, keypad Enter).
        case foot(Int, Double)
        case spacer(Double)

        var units: Double {
            switch self {
            case .key(_, _, let m), .keys(_, _, let m), .symbol(_, _, let m), .stack(_, _, let m): return m
            case .blank(let m), .spacer(let m), .foot(_, let m): return m
            }
        }
        /// Every code the tile lights for.
        var codes: [Int] {
            switch self {
            case .key(let c, _, _): return [c]
            case .keys(let cs, _, _), .symbol(let cs, _, _): return cs
            case .stack(let a, let b, _): return [a, b]
            case .foot(let c, _): return [c]
            case .blank, .spacer: return []
            }
        }
    }
}

/// The keyboard map's choices, in the Live Visualizer's keyboard header:
/// its shape, which layout labels the keys, and when the number pad shows.
struct KeyboardMapMenu: View {
    @ObservedObject private var layout = KeyboardLayoutService.shared
    @State private var layouts: [KeyboardLayoutService.LayoutChoice] = []

    var body: some View {
        Menu {
            Section(String(localized: "Shape")) {
                Button {
                    layout.shapeOverride = nil
                } label: {
                    check(layout.shapeOverride == nil,
                          String(localized: "Automatic (\(layout.detectedShape.label))"))
                }
                ForEach(KeyboardLayoutService.Shape.allCases) { s in
                    Button { layout.shapeOverride = s } label: { check(layout.shapeOverride == s, s.label) }
                }
            }
            Section(String(localized: "Key labels")) {
                Button { layout.labelSourceID = "" } label: {
                    check(layout.labelSourceID.isEmpty, String(localized: "Follow the input source"))
                }
                Menu(String(localized: "Another layout")) {
                    ForEach(layouts) { choice in
                        Button { layout.labelSourceID = choice.id } label: {
                            check(layout.labelSourceID == choice.id, choice.name)
                        }
                    }
                }
            }
            Section(String(localized: "Number pad and navigation keys")) {
                ForEach(KeyboardLayoutService.ExtendedKeys.allCases) { e in
                    Button { layout.extendedKeys = e } label: { check(layout.extendedKeys == e, e.label) }
                }
            }
        } label: {
            Text(verbatim: "\(layout.shape.label), \(layout.sourceName)")
                .font(.caption2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "The keyboard's shape, the layout its keys are labeled in, and when the number pad shows"))
        .accessibilityLabel("Keyboard map")
        .accessibilityValue("\(layout.shape.label), \(layout.sourceName)")
        .onAppear { if layouts.isEmpty { layouts = layout.installedLayouts() } }
    }

    @ViewBuilder
    private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
