import SwiftUI

/// Flat macOS keyboard layout for the Live Visualizer. Renders the
/// six standard QWERTY rows (function, number, top, home, bottom,
/// modifier) plus an optional numeric keypad on the right when the
/// preset has any numpad keys bound. Each key tile lights up green
/// when pressed (via `ExternalInputDeviceService.rawActiveInputs`),
/// stays at full opacity if a binding targets it, and dims when it
/// has no binding in this slot.
struct KeyboardDiagramView: View {
    /// HID keycodes (from `InputEvent.index` for `.extKey`) that are
    /// bound by this slot in the preset. Drives the "in colour vs
    /// dimmed" treatment.
    let boundKeyCodes: Set<Int>
    /// HID keycodes currently pressed - drawn green on top of the base.
    let pressedKeyCodes: Set<Int>

    /// Standard keyboard rows. Each tuple is (HID code, label, width
    /// multiplier where 1.0 = single key). nil HID means "spacer",
    /// rendered as transparent space.
    private static let mainRows: [[Key]] = [
        // Function row
        [
            .key(41,  "esc", 1.0),
            .spacer(0.25),
            .key(58,  "F1", 1.0),  .key(59,  "F2", 1.0),
            .key(60,  "F3", 1.0),  .key(61,  "F4", 1.0),
            .spacer(0.25),
            .key(62,  "F5", 1.0),  .key(63,  "F6", 1.0),
            .key(64,  "F7", 1.0),  .key(65,  "F8", 1.0),
            .spacer(0.25),
            .key(66,  "F9", 1.0),  .key(67,  "F10", 1.0),
            .key(68,  "F11", 1.0), .key(69,  "F12", 1.0)
        ],
        // Number row
        [
            .key(53,  "`", 1.0),
            .key(30,  "1", 1.0), .key(31,  "2", 1.0), .key(32,  "3", 1.0),
            .key(33,  "4", 1.0), .key(34,  "5", 1.0), .key(35,  "6", 1.0),
            .key(36,  "7", 1.0), .key(37,  "8", 1.0), .key(38,  "9", 1.0),
            .key(39,  "0", 1.0),
            .key(45,  "-", 1.0), .key(46,  "=", 1.0),
            .key(42,  "⌫", 1.5)
        ],
        // Top alpha row
        [
            .key(43,  "⇥", 1.5),
            .key(20,  "Q", 1.0), .key(26,  "W", 1.0), .key(8,   "E", 1.0),
            .key(21,  "R", 1.0), .key(23,  "T", 1.0), .key(28,  "Y", 1.0),
            .key(24,  "U", 1.0), .key(12,  "I", 1.0), .key(18,  "O", 1.0),
            .key(19,  "P", 1.0),
            .key(47,  "[", 1.0), .key(48,  "]", 1.0), .key(49,  "\\", 1.0)
        ],
        // Home row
        [
            .key(57,  "⇪", 1.75),
            .key(4,   "A", 1.0), .key(22,  "S", 1.0), .key(7,   "D", 1.0),
            .key(9,   "F", 1.0), .key(10,  "G", 1.0), .key(11,  "H", 1.0),
            .key(13,  "J", 1.0), .key(14,  "K", 1.0), .key(15,  "L", 1.0),
            .key(51,  ";", 1.0), .key(52,  "'", 1.0),
            .key(40,  "↩", 1.75)
        ],
        // Bottom alpha row
        [
            .key(225, "⇧", 2.25),
            .key(29,  "Z", 1.0), .key(27,  "X", 1.0), .key(6,   "C", 1.0),
            .key(25,  "V", 1.0), .key(5,   "B", 1.0), .key(17,  "N", 1.0),
            .key(16,  "M", 1.0),
            .key(54,  ",", 1.0), .key(55,  ".", 1.0), .key(56,  "/", 1.0),
            .key(229, "⇧", 2.25)
        ],
        // Modifier row
        [
            .key(224, "⌃", 1.25), .key(226, "⌥", 1.25), .key(227, "⌘", 1.25),
            .key(44,  "space", 6.25),
            .key(231, "⌘", 1.25), .key(230, "⌥", 1.25),
            .key(80,  "◀", 1.0),  .key(81,  "▼", 1.0),
            .key(82,  "▲", 1.0),  .key(79,  "▶", 1.0)
        ]
    ]

    /// Optional numpad block. Shown when the preset binds any of these
    /// numpad-region HID codes.
    private static let numpadRows: [[Key]] = [
        [.key(83,  "Clear", 1.0), .key(84,  "/", 1.0), .key(85,  "*", 1.0), .key(86,  "-", 1.0)],
        [.key(95,  "7", 1.0), .key(96,  "8", 1.0), .key(97,  "9", 1.0), .key(87,  "+", 1.0)],
        [.key(92,  "4", 1.0), .key(93,  "5", 1.0), .key(94,  "6", 1.0), .spacer(1.0)],
        [.key(89,  "1", 1.0), .key(90,  "2", 1.0), .key(91,  "3", 1.0), .key(88,  "↩", 1.0)],
        [.key(98,  "0", 2.0), .key(99,  ".", 1.0), .spacer(1.0)]
    ]

    private var hasNumpadBindings: Bool {
        // HID keypad usage range is 83-99 per the HID Keyboard usage table.
        boundKeyCodes.contains { (83...99).contains($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.mainRows.indices, id: \.self) { rowIdx in
                    keyRow(Self.mainRows[rowIdx])
                }
            }
            if hasNumpadBindings {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Numpad")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(Self.numpadRows.indices, id: \.self) { rowIdx in
                        keyRow(Self.numpadRows[rowIdx])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ keys: [Key]) -> some View {
        HStack(spacing: 3) {
            ForEach(keys.indices, id: \.self) { idx in
                tileFor(keys[idx])
            }
        }
    }

    @ViewBuilder
    private func tileFor(_ key: Key) -> some View {
        switch key {
        case .spacer(let mult):
            Color.clear
                .frame(width: keyUnit * CGFloat(mult), height: keyUnit)
        case .key(let hid, let label, let mult):
            let pressed = pressedKeyCodes.contains(hid)
            let bound = boundKeyCodes.contains(hid)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(pressed ? Color.green.opacity(0.85)
                                   : Color.secondary.opacity(bound ? 0.22 : 0.08))
                RoundedRectangle(cornerRadius: 4)
                    .stroke(pressed ? Color.green
                                    : Color.secondary.opacity(bound ? 0.55 : 0.2),
                            lineWidth: pressed ? 1.5 : 0.75)
                Text(label)
                    .font(.system(size: 9, weight: pressed ? .semibold : .regular))
                    .foregroundStyle(pressed ? .white
                                              : (bound ? Color.primary : Color.secondary))
                    .padding(.horizontal, 2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: keyUnit * CGFloat(mult), height: keyUnit)
        }
    }

    /// Size of a single key tile. Picked so the full keyboard fits in
    /// the visualizer column without horizontal scrolling.
    private let keyUnit: CGFloat = 22

    enum Key {
        case key(Int, String, Double)
        case spacer(Double)
    }
}
