import SwiftUI

/// The app for someone who only ever starts a preset: big buttons for the
/// favorites, and a still crib sheet of what the chosen one does. No editor and
/// nothing that moves or flashes, since the point is a screen a person with low
/// vision or little patience for menus can use alone. A helper turns it on from
/// the View menu; it stays on across launches.
struct SimpleLauncherView: View {
    static let enabledKey = "InputConfig.simpleView"

    @EnvironmentObject private var presetStore: PresetStore
    @EnvironmentObject private var controllerService: GameControllerService
    let onToggle: (Preset) -> Void
    let onLeave: () -> Void
    @State private var chosenID: UUID?
    @State private var picture: NSImage?

    /// The favorites, or everything when none are starred.
    private var shown: [Preset] {
        let favorites = presetStore.favoritePresets
        return favorites.isEmpty ? presetStore.presets : favorites
    }

    private var chosen: Preset? {
        shown.first { $0.id == chosenID } ?? shown.first { $0.isActive } ?? shown.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(shown) { preset in card(preset) }
                    }
                    .padding(.vertical, 2)
                }
                Button("Show All Presets") { onLeave() }
                    .controlSize(.large)
            }
            .frame(width: 320)
            .padding(20)
            Divider()
            if let chosen { crib(chosen) } else { Color.white }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: chosen?.id) {
            picture = chosen.flatMap {
                PresetPrint.drawing($0, slot: 0, controllers: controllerService, width: 640)
            }
        }
    }

    /// One press starts the preset and shows its sheet; pressing the running
    /// one stops it.
    private func card(_ preset: Preset) -> some View {
        Button {
            chosenID = preset.id
            onToggle(preset)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.isActive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.title3.weight(.semibold))
                    if preset.isActive { Text("Running").font(.callout) }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(preset.isActive ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(preset.isActive ? Color.accentColor : Color.secondary.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(preset.id == chosen?.id ? Color.primary : Color.clear, lineWidth: 2))
        .accessibilityLabel(preset.name)
        .accessibilityValue(preset.isActive ? Text("Running") : Text("Stopped"))
    }

    /// Black on white in any appearance, like the printed page.
    private func crib(_ preset: Preset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(preset.name).font(.largeTitle.weight(.bold))
                let notes = (preset.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !notes.isEmpty { Text(ShippedText.t(notes)).font(.title3) }
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 700)
                        .accessibilityHidden(true)
                }
                ForEach(0..<preset.joysticks.count, id: \.self) { slot in
                    ForEach(preset.joysticks[slot].bindings) { row in
                        let line = PresetPrint.summary(of: row, in: preset)
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(line.name).font(.title3.weight(.semibold)).frame(width: 200, alignment: .leading)
                            Text(line.does.replacingOccurrences(of: "\u{2028}", with: "\n")).font(.title3)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .foregroundStyle(Color.black)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

/// The View menu's switch, checked while Simple View is on.
struct SimpleViewCommand: View {
    @AppStorage(SimpleLauncherView.enabledKey) private var enabled = false
    var body: some View {
        Toggle("Simple View", isOn: $enabled)
    }
}
