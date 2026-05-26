import SwiftUI

/// A Slider wrapper that holds the dragging value locally and only writes
/// to the bound value when the user releases the slider. This is essential
/// inside the preset editor because every write to a binding propagates
/// through several layers of value-type structs (OutputAction → BindingModel
/// → JoystickMapping → Preset) and re-renders the entire editor on every
/// frame. SwiftUI's plain Slider fires the setter dozens of times per
/// second while dragging, causing visible lag with non-trivial view trees.
struct ThrottledSlider<V: BinaryFloatingPoint>: View
where V.Stride: BinaryFloatingPoint {
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    /// Optional callback fired on every value change including each drag
    /// tick. The upstream `value` is still only written on release; this
    /// closure lets callers mirror the live value into lightweight local
    /// state so a value label or TextField can update in real time without
    /// triggering the heavy Preset re-render chain.
    var onLiveChange: ((V) -> Void)?

    @State private var localValue: V
    @State private var isDragging = false

    init(
        value: Binding<V>,
        in range: ClosedRange<V>,
        step: V.Stride = 1,
        onLiveChange: ((V) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.onLiveChange = onLiveChange
        self._localValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        Slider(
            value: $localValue,
            in: range,
            step: step,
            onEditingChanged: { editing in
                isDragging = editing
                if !editing {
                    // Commit the final value once the user releases the thumb.
                    value = localValue
                }
            }
        )
        .onChange(of: localValue) { _, newValue in
            onLiveChange?(newValue)
        }
        .onChange(of: value) { _, newValue in
            // If the upstream value changes from elsewhere (e.g. preset
            // load), keep our local state in sync, but only when we are
            // not actively dragging.
            if !isDragging && abs(Double(newValue - localValue)) > 0.0001 {
                localValue = newValue
            }
        }
    }
}
