import SwiftUI

/// A joystick group showing its header and list of bindings.
/// Observes mappingEngine directly so highlight state updates in real-time.
struct JoystickGroupView: View {
    @SwiftUI.Binding var joystick: JoystickMapping
    let joystickIndex: Int
    let controllerName: String
    let onAddBinding: () -> Void
    let onRemoveBinding: (Int) -> Void
    let onDuplicateBinding: (Int) -> Void
    let onScanInput: (Int) -> Void
    let onSortBindings: () -> Void
    let onDuplicate: () -> Void
    let onRemoveJoystick: () -> Void
    /// Binding UUID currently pulsing (jump-to-binding from Live Visualizer).
    /// nil when no pulse is active.
    var pulsingBindingID: UUID? = nil

    @EnvironmentObject var mappingEngine: MappingEngine
    @EnvironmentObject var controllerService: GameControllerService
    @State private var preSortSnapshot: [BindingModel]?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if joystick.isExpanded {
                // Use `bindings.indices` instead of `Array(...).enumerated()`
                // to avoid allocating a new array on every render.
                LazyVStack(spacing: 2) {
                    ForEach(joystick.bindings.indices, id: \.self) { index in
                        let binding = joystick.bindings[index]
                        BindingRowView(
                            binding: bindingAt(index),
                            onScan: { onScanInput(index) },
                            onRemove: { onRemoveBinding(index) },
                            onDuplicate: { onDuplicateBinding(index) },
                            // Light up against raw controller state OR the
                            // engine's preset-aware set, whichever is firing.
                            // This works even with no preset active.
                            isHighlighted:
                                mappingEngine.activeInputsPublished.contains(binding.input.serialized)
                                || controllerService.rawActiveInputs.contains(binding.input.serialized),
                            displayNumber: index + 1,
                            isPulsing: pulsingBindingID == binding.id
                        )
                        .id(binding.id)
                    }
                }
                .padding(.vertical, 2)
                // Suppress implicit transitions on row insertion/removal so
                // scrolling does not trigger animation work for new rows.
                .animation(nil, value: joystick.bindings.count)

                Button(action: onAddBinding) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.green)
                        Text("Add a new bind")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.green.opacity(0.03))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { joystick.isExpanded.toggle() }
            } label: {
                Image(systemName: joystick.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Joystick #\(joystickIndex)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(":")
                        .foregroundStyle(.tertiary)
                    Text(controllerName)
                        .font(.caption)
                        .foregroundStyle(controllerName.contains("No controller") ? .red.opacity(0.6) : .primary)
                        .lineLimit(1)
                }
                TextField("Tag / comment", text: $joystick.tag)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    preSortSnapshot = joystick.bindings
                    onSortBindings()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Sort bindings")

                if preSortSnapshot != nil {
                    Button {
                        if let snapshot = preSortSnapshot {
                            withAnimation { joystick.bindings = snapshot }
                            preSortSnapshot = nil
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Undo sort")
                }

                CopyIconButton(action: onDuplicate,
                               helpText: "Clone this joystick group",
                               size: .caption)

                Button(action: onRemoveJoystick) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this joystick group")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func bindingAt(_ index: Int) -> SwiftUI.Binding<BindingModel> {
        SwiftUI.Binding(
            get: { joystick.bindings[index] },
            set: { joystick.bindings[index] = $0 }
        )
    }
}
