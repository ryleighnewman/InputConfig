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

    /// The favorites, or everything when none are starred: as the sidebar
    /// orders it, without the built ins the person hid.
    private var shown: [Preset] {
        Self.shown(favorites: presetStore.favoritePresets, all: presetStore.presets,
                   hidden: { presetStore.isHiddenBuiltIn($0) },
                   order: { presetStore.inSidebarOrder($0) })
    }
    static func shown(favorites: [Preset], all: [Preset], hidden: (Preset) -> Bool,
                      order: ([Preset]) -> [Preset]) -> [Preset] {
        favorites.isEmpty ? order(all.filter { !hidden($0) }) : favorites
    }

    private var chosen: Preset? { Self.chosen(in: shown, id: chosenID) }
    private static func chosen(in shown: [Preset], id: UUID?) -> Preset? {
        shown.first { $0.id == id } ?? shown.first { $0.isActive } ?? shown.first
    }

    var body: some View {
        // Worked out once a pass: the list is sorted, and every card asks
        // which one is chosen.
        let list = shown
        let pick = Self.chosen(in: list, id: chosenID)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(list) { preset in card(preset, chosen: preset.id == pick?.id) }
                    }
                    .padding(.vertical, 2)
                }
                Button("Show All Presets") { onLeave() }
                    .controlSize(.large)
            }
            .frame(width: 320)
            .padding(20)
            Divider()
            if let pick { crib(pick) } else { Color.white }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: pick?.id) {
            picture = self.chosen.flatMap {
                PresetPrint.drawing($0, slot: 0, controllers: controllerService, width: 640)
            }
        }
    }

    /// One press starts the preset and shows its sheet; pressing the running
    /// one stops it. A preset with nothing to run is dimmed and takes no
    /// press: starting it did nothing and said nothing.
    private func card(_ preset: Preset, chosen: Bool) -> some View {
        Button {
            chosenID = preset.id
            onToggle(preset)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.isActive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.shownName).font(.title3.weight(.semibold))
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
            .strokeBorder(chosen ? Color.primary : Color.clear, lineWidth: 2))
        .disabled(!preset.isRunnable && !preset.isActive)
        .opacity(preset.isRunnable || preset.isActive ? 1 : 0.5)
        .accessibilityLabel(preset.shownName)
        .accessibilityValue(preset.isActive ? Text("Running") : Text("Stopped"))
    }

    /// Black on white in any appearance, like the printed page.
    private func crib(_ preset: Preset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(preset.shownName).font(.largeTitle.weight(.bold))
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
