import SwiftUI

/// Tiny copy / duplicate button that morphs into a green checkmark for ~1 s
/// after each successful click, then morphs back. Use anywhere we previously
/// had a bare `Image(systemName: "doc.on.doc")` button so the user sees
/// confirmation that the click registered.
///
/// Designed for compact toolbar / row contexts: caller passes the action and
/// the rendered icon styling matches the existing duplicate / copy buttons.
struct CopyIconButton: View {
    let action: () -> Void
    /// Hover tooltip ("Duplicate this binding", "Copy log to clipboard", etc.)
    var helpText: String = "Copy"
    /// Default icon. Override when the source icon isn't the standard
    /// "doc.on.doc" (currently nothing else uses this, but kept flexible).
    var icon: String = "doc.on.doc"
    /// Icon size. Match the surrounding font weight where the button lives.
    var size: Font = .caption2
    var tint: Color = .secondary

    @State private var justCopied: Bool = false

    var body: some View {
        Button {
            action()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                justCopied = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeOut(duration: 0.3)) {
                    justCopied = false
                }
            }
        } label: {
            // Symbol cross-fade looks like a real morph because both glyphs
            // share roughly the same bounding box.
            ZStack {
                Image(systemName: icon)
                    .opacity(justCopied ? 0 : 1)
                    .scaleEffect(justCopied ? 0.7 : 1)
                Image(systemName: "checkmark.circle.fill")
                    .opacity(justCopied ? 1 : 0)
                    .scaleEffect(justCopied ? 1 : 0.7)
                    .foregroundStyle(.green)
            }
            .font(size)
            .foregroundStyle(justCopied ? .green : tint)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
