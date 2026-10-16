import SwiftUI
import AppKit

/// Picker for selecting a keyboard key by HID usage code, grouped by category.
///
/// Uses SwiftUI's `Menu` instead of `Picker` because `Picker` on macOS
/// instantiates every menu item up front (NSPopUpButton pre-population),
/// which becomes a real performance problem when many rows are visible
/// in the preset editor. `Menu` only builds its contents the first time
/// the user opens the menu, so the editor opens dramatically faster.
struct KeyCodePicker: View {
    @SwiftUI.Binding var selectedCode: Int
    /// Part of a Command or Control shortcut: letters and punctuation are
    /// sent by character, so they are listed and named by it.
    var inShortcut: Bool = false
    /// What Voice Control answers to after the key shown: "click A" or
    /// "click Key".
    var voiceRole: LocalizedStringKey = "Key"
    /// Key names follow the input source; a change to it redraws the picker.
    @ObservedObject private var keyboardLayout = KeyboardLayoutService.shared

    private var displayName: String {
        KeyCodeMap.outputName(for: selectedCode, inShortcut: inShortcut)
    }

    var body: some View {
        SearchableMenu(choices: {
            KeyCodeMap.groups.flatMap { group in
                (KeyCodeMap.keysByGroup[group] ?? []).map { key in
                    let name = KeyCodeMap.outputName(for: key.code, inShortcut: inShortcut)
                    return MenuSearchChoice(title: name, path: group,
                                            keywords: key.name + " " + HotKeySpec.spokenKey(name),
                                            spokenTitle: HotKeySpec.spokenKey(name)) { selectedCode = key.code }
                }
            }
        }) {
            ForEach(KeyCodeMap.groups, id: \.self) { group in
                Menu(group) {
                    ForEach(KeyCodeMap.keysByGroup[group] ?? []) { key in
                        Button(KeyCodeMap.outputName(for: key.code, inShortcut: inShortcut)) {
                            selectedCode = key.code
                        }
                        .accessibilityLabel(HotKeySpec.spokenKey(KeyCodeMap.outputName(for: key.code, inShortcut: inShortcut)))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        // Expose the selected key as the accessibility VALUE so call sites can
        // set a role label (for example "Accelerate key") without erasing the
        // key name for VoiceOver.
        // A lone mark ("," or "-") by name: VoiceOver drops it otherwise.
        .accessibilityValue(HotKeySpec.spokenKey(displayName))
        .accessibilityInputLabels([Text(displayName), Text(voiceRole)])
    }
}

// MARK: - Searchable menus

/// One choice a searchable menu offers: what the menu calls it, where it
/// sits in the menu ("Keyboard › Key › Letter Keys"), and other words it
/// may be found by, such as a key's spoken name.
struct MenuSearchChoice {
    let title: String
    var path: String = ""
    var keywords: String = ""
    var systemImage: String? = nil
    /// The name VoiceOver says when the title is a lone mark ("," or "-").
    var spokenTitle: String? = nil
    let run: () -> Void

    /// Joins the menu names a choice sits under.
    static func path(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " \u{203A} ")
    }
}

enum MenuSearch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    /// The choices that hold every typed word, in their name, their place
    /// in the menu or their other words, best first: the exact name, then
    /// a name that starts with what was typed, then a word in the name
    /// that does, then the rest in menu order.
    static func matches(_ choices: [MenuSearchChoice], query: String) -> [Int] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return Array(choices.indices) }
        let whole = words.joined(separator: " ")
        var ranked: [(rank: Int, index: Int)] = []
        for (index, choice) in choices.enumerated() {
            let title = fold(choice.title)
            let text = title + " " + fold(choice.path) + " " + fold(choice.keywords)
            guard words.allSatisfy({ text.contains($0) }) else { continue }
            let titleWords = title.split { !$0.isLetter && !$0.isNumber }
            let rank = title == whole ? 0
                : title.hasPrefix(whole) ? 1
                : titleWords.contains(where: { $0.hasPrefix(first) }) ? 2
                : title.contains(first) ? 3 : 4
            ranked.append((rank, index))
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.index)
    }
}

/// A dropdown with Search at the top. A Mac menu cannot hold a working
/// text field, so the item opens a small panel under the dropdown that
/// finds any of its choices, nested ones too, as you type. The choices are
/// built only when the panel opens, so rows still render without them.
struct SearchableMenu<Content: View, MenuLabel: View>: View {
    let choices: () -> [MenuSearchChoice]
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> MenuLabel
    @State private var searching = false

    init(choices: @escaping () -> [MenuSearchChoice],
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder label: @escaping () -> MenuLabel) {
        self.choices = choices
        self.content = content
        self.label = label
    }

    var body: some View {
        Menu {
            Button {
                // Once the menu has closed: a popover asked for while it is
                // still open is dismissed along with it.
                DispatchQueue.main.async { searching = true }
            } label: {
                Label("Search\u{2026}", systemImage: "magnifyingglass")
            }
            Divider()
            content()
        } label: {
            label()
        }
        .popover(isPresented: $searching, arrowEdge: .bottom) {
            MenuSearchPanel(choices: choices(), close: { searching = false })
        }
    }
}

/// The panel Search opens: a field, then the choices that match. Up and
/// Down move through them, Return picks the highlighted one, Escape closes.
struct MenuSearchPanel: View {
    let choices: [MenuSearchChoice]
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @Environment(\.appTextScale) private var textScale

    /// Grows with the app's Text Size, so a larger row never overlaps the next.
    private var rowHeight: CGFloat { 24 * max(1, textScale) }

    var body: some View {
        let hits = MenuSearch.matches(choices, query: query)
        VStack(spacing: 0) {
            MenuSearchField(text: $query,
                            move: { step in
                                guard !hits.isEmpty else { return }
                                highlighted = min(max(highlighted + step, 0), hits.count - 1)
                            },
                            submit: { if hits.indices.contains(highlighted) { pick(hits[highlighted]) } },
                            cancel: close)
                .frame(height: 22)
                .padding(8)
            Divider()
            if hits.isEmpty {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(hits.enumerated()), id: \.offset) { position, index in
                                row(choices[index], lit: position == highlighted) { pick(index) }
                                    .id(position)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
                }
                .frame(height: min(CGFloat(hits.count) * rowHeight + 8, 14 * rowHeight + 8))
            }
        }
        .frame(width: 340 * min(1.6, max(1, textScale)))
        .onChange(of: query) { _, _ in
            highlighted = 0
            announce(hits: MenuSearch.matches(choices, query: query))
        }
        .onChange(of: highlighted) { _, _ in announce(hits: hits) }
    }

    /// Up, Down and typing move a highlight the field keeps the focus
    /// through, so VoiceOver hears which choice Return will pick.
    private func announce(hits: [Int]) {
        let text = hits.indices.contains(highlighted) ? spokenLabel(choices[hits[highlighted]]) : String(localized: "No matches")
        AccessibilityNotification.Announcement(text).post()
    }

    private func spokenLabel(_ choice: MenuSearchChoice) -> String {
        let name = choice.spokenTitle ?? choice.title
        return choice.path.isEmpty ? name : "\(name), \(choice.path)"
    }

    private func row(_ choice: MenuSearchChoice, lit: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = choice.systemImage {
                    Image(systemName: icon)
                        .frame(width: 16)
                }
                Text(choice.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(choice.path)
                    .font(.caption)
                    .foregroundStyle(lit ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(.callout)
            .foregroundStyle(lit ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel(choice))
        .accessibilityInputLabels([Text(choice.spokenTitle ?? choice.title), Text(choice.title)])
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    private func pick(_ index: Int) {
        let run = choices[index].run
        close()
        // After the popover is gone, so a choice that opens a sheet or
        // another panel is not shown under it.
        DispatchQueue.main.async { run() }
    }
}

/// The panel's search field: a Mac search field that takes the keyboard as
/// soon as it appears and hands Up, Down, Return and Escape to the list.
private struct MenuSearchField: NSViewRepresentable {
    @SwiftUI.Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusingSearchField()
        field.placeholderString = String(localized: "Search")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(String(localized: "Search this menu"))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MenuSearchField
        init(_ parent: MenuSearchField) { self.parent = parent }

        @objc func changed(_ sender: NSSearchField) {
            if parent.text != sender.stringValue { parent.text = sender.stringValue }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            changed(field)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}

/// Takes the keyboard when the popover shows it, so typing goes straight in.
private final class FocusingSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
