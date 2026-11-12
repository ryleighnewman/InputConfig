import SwiftUI
import SceneKit
import Metal
import GameController
import UniformTypeIdentifiers

// MARK: - Preset Row View

struct PresetRowView: View {
    let preset: Preset
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onShowInFinder: () -> Void
    let onShare: () -> Void
    let onImport: () -> Void
    let onDelete: () -> Void
    let onConvert: (ControllerType, ControllerType) -> Void
    /// Every folder, as "Parent / Child" paths, for Move to Group.
    var groupChoices: [(id: UUID, path: String)] = []
    var currentGroupID: UUID? = nil
    var onMoveToGroup: (UUID?) -> Void = { _ in }
    var onNewGroup: () -> Void = { }
    /// Starred: a small star before the name, and the menus offer to remove it.
    var isFavorite: Bool = false
    var onToggleFavorite: () -> Void = { }
    /// Whether the row is the selected one: a click on its description then
    /// opens the full text, while the first click only selects it. Read
    /// here, in this body, so a switch redraws this row without the sidebar
    /// making every row again (SidebarRows).
    var selection: PresetRowSelection? = nil
    var onMove: (Bool) -> Void = { _ in }

    private var isSelected: Bool { selection?.isSelected ?? false }

    /// Toggled when the user clicks the trailing ellipsis next to a
    /// truncated description. Collapses back when toggled off, the row is
    /// deselected, or another row is selected.
    @State private var descriptionExpanded: Bool = false

    /// Active state is normally conveyed only by the green row tint;
    /// with Differentiate Without Color on we add a glyph as well.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.appHighContrast) private var appHighContrast

    /// Whether the row should offer an expand toggle. We err on the side
    /// of showing it: any non-trivial tag (>= 16 chars, since sidebar
    /// width often clips around there) OR any notes content qualifies.
    /// 16 instead of 40 means narrow-sidebar users actually get the
    /// button when their text is in fact truncated.
    private var descriptionTruncates: Bool {
        preset.tag.count >= 16 || !preset.notes.isEmpty
    }

    var body: some View {
        #if DEBUG
        let _ = BodyRuns.note("PresetRowView")
        #endif
        // Single-line row: name on top, optional chevron beside the
        // truncated tag. Clicking the chevron pops up the full
        // description as a popover floating below the row. We use a
        // popover instead of inline expansion because List(.sidebar)
        // enforces a fixed row height that silently clips any
        // multi-line text - the popover floats outside the row
        // entirely and is guaranteed to show the full text.
        mainRow
    }

    /// Everything a preset row offers, shared by the trailing ellipsis
    /// menu and the right-click menu so the two never drift apart.
    @ViewBuilder
    private var optionsMenuItems: some View {
        Button(preset.isActive ? String(localized: "Deactivate") : String(localized: "Activate")) {
            onActivate()
        }
        // As the page's button: a preset with nothing to run cannot start,
        // and the menu item did nothing and said nothing.
        .disabled(!preset.isActive && !preset.isRunnable)

        Button("Edit") {
            onEdit()
        }

        Button("Duplicate") {
            onDuplicate()
        }

        Button(isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
            onToggleFavorite()
        }

        Divider()

        Menu("Move to Group") {
            ForEach(groupChoices, id: \.id) { choice in
                Button {
                    onMoveToGroup(choice.id)
                } label: {
                    if choice.id == currentGroupID {
                        Label(choice.path, systemImage: "checkmark")
                    } else {
                        Text(choice.path)
                    }
                }
                .disabled(choice.id == currentGroupID)
            }
            if !groupChoices.isEmpty { Divider() }
            Button("New Group…") { onNewGroup() }
            if currentGroupID != nil {
                Button("Remove from Group") { onMoveToGroup(nil) }
            }
        }

        Divider()

        Menu("Convert To…") {
            ForEach(ControllerType.allCases.filter { !$0.conversionTargets.isEmpty }) { sourceType in
                Menu("From \(sourceType.displayName)") {
                    ForEach(sourceType.conversionTargets) { destType in
                        Button("To \(destType.displayName)") {
                            onConvert(sourceType, destType)
                        }
                    }
                }
            }
        }

        Button("Export…") {
            onExport()
        }

        Button("Import Preset File…") {
            onImport()
        }

        Divider()

        Button("Show in Finder") {
            onShowInFinder()
        }

        Button("Share…") {
            onShare()
        }

        Divider()

        // Reordering without a drag, for dwell and switch users.
        Button("Move Up") { onMove(true) }
        Button("Move Down") { onMove(false) }

        Divider()

        Button("Delete", role: .destructive) {
            onDelete()
        }
    }

    /// Top half of the row: name, single-line description with the trailing
    /// ellipsis-toggle, then the trailing options Menu. Always the same
    /// height regardless of expansion.
    @ViewBuilder
    private var mainRow: some View {
        HStack(spacing: 6) {
            // The running preset by more than a faint tint when color or
            // contrast is a problem.
            if preset.isActive && (differentiateWithoutColor || contrast == .increased || appHighContrast) {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .iconTint(.green)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow.opacity(0.7))
                            .accessibilityLabel("Favorite")
                    }
                    Text(preset.shownName)
                        .font(.body)
                        .lineLimit(1)
                }

                // Single-line tag preview. When it truncates, clicking it
                // (the ellipsis is the cue) floats the full description
                // below the row. A popover rather than growing the row:
                // List(.sidebar) clips multi-line rows.
                Text(preset.shownTag)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    // The click still selects the row; the popover opens only
                    // on a row already selected, so a dwell click meant to
                    // select does not cover the rows below, and only once the
                    // button is up, so dragging the row opens nothing.
                    .background(SidebarClickTarget {
                        guard descriptionTruncates && isSelected && !descriptionExpanded else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            if NSEvent.pressedMouseButtons == 0 { descriptionExpanded = true }
                        }
                    })
                    .popover(isPresented: $descriptionExpanded, arrowEdge: .bottom) {
                        descriptionPopover
                    }
                    .help(descriptionTruncates ? String(localized: "Click to read the whole description") : "")
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(preset.isActive ? String(localized: "Active") : String(localized: "Inactive"))
            // Voice Control answers to the name, not the whole tag line.
            .accessibilityInputLabels([Text(preset.shownName)])
            // Running is said by the value; "selected" is the list's own state.
            .accessibilityAction(named: "Show full description") {
                if descriptionTruncates { descriptionExpanded = true }
            }

            Spacer(minLength: 4)

            // Options menu
            Menu {
                optionsMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    // The only sign of the menu: full gray when more contrast is asked for.
                    .foregroundColor(contrast == .increased || appHighContrast ? Color.secondary : Color.gray.opacity(0.55))
                    .frame(width: 16, height: 22, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 16, alignment: .trailing)
            .accessibilityLabel("\(preset.shownName) options")
            .accessibilityHint("Activate, edit, duplicate, convert, share, or delete this preset")
        }
        .padding(.vertical, 4)
        // The whole row, the empty stretch of its green highlight included,
        // answers a right-click with the ellipsis menu.
        .contentShape(Rectangle())
        .contextMenu {
            optionsMenuItems
        }
    }

    /// Floating popover anchored to the chevron button. Renders OUTSIDE
    /// the List row container so the sidebar's fixed-row-height
    /// enforcement can't clip multi-line text. The popover has its
    /// own fixed width (280pt) and grows vertically with the content.
    @ViewBuilder
    private var descriptionPopover: some View {
        // Long notes scroll inside the popover instead of growing it past
        // the screen; the name and tag stay put above the scrolling part.
        VStack(alignment: .leading, spacing: 8) {
            Text(preset.shownName)
                .font(.headline)
            if !preset.tag.isEmpty {
                Text(preset.shownTag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !preset.notes.isEmpty {
                Divider()
                Text("Notes")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.hint)
                ScrollView(.vertical) {
                    Text(ShippedText.t(preset.notes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

// MARK: - Preset Detail View

/// Text typed on the detail page and not saved yet. The page sets
/// `commit`; ContentView runs it before the editor or the engine takes the
/// preset. A plain box (not observed), like VisualizerControlBox.
@MainActor
final class PresetPageDrafts {
    var commit: @MainActor () -> Void = {}
}

/// The page's name and tag as typed, with the preset they were typed on, so
/// a switch writes them to that preset and never shows them on the next.
struct PresetHeaderDraft {
    let presetID: UUID
    var name: String?
    var tag: String?

    /// The typed text of one field, only on the preset it was typed on.
    func text(_ field: KeyPath<PresetHeaderDraft, String?>, on id: UUID) -> String? {
        presetID == id ? self[keyPath: field] : nil
    }

    /// Writes the typed text into `preset`; true when anything changed.
    func apply(to preset: inout Preset) -> Bool {
        var changed = false
        if let name, name != preset.name { preset.name = name; changed = true }
        if let tag, tag != preset.tag { preset.tag = tag; changed = true }
        return changed
    }
}
