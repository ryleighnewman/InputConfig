import SwiftUI

/// Picker for selecting a keyboard key by HID usage code, grouped by category.
///
/// Uses SwiftUI's `Menu` instead of `Picker` because `Picker` on macOS
/// instantiates every menu item up front (NSPopUpButton pre-population),
/// which becomes a real performance problem when many rows are visible
/// in the preset editor. `Menu` only builds its contents the first time
/// the user opens the menu, so the editor opens dramatically faster.
struct KeyCodePicker: View {
    @SwiftUI.Binding var selectedCode: Int

    private var displayName: String {
        KeyCodeMap.name(for: selectedCode)
    }

    var body: some View {
        Menu {
            ForEach(KeyCodeMap.groups, id: \.self) { group in
                Menu(group) {
                    ForEach(KeyCodeMap.keysByGroup[group] ?? []) { key in
                        Button(key.name) {
                            selectedCode = key.code
                        }
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
    }
}
