import SwiftUI
import StoreKit

/// The "would you rate it?" card. Saying yes hands off to the system review
/// sheet, where a star can be tapped right there; the card itself never
/// collects a rating (Apple does not allow that) and never conditions
/// anything on the answer.
struct ReviewPromptView: View {
    @ObservedObject private var review = ReviewPromptService.shared
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                }
            }
            .accessibilityHidden(true)
            .padding(.top, 6)

            Text("Enjoying InputConfig?")
                .font(.title3.weight(.semibold))

            Text("If it's been making your Mac easier to use, would you be willing to give it a star rating?")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("(It only takes a little push. It helps us so much.)")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button {
                    review.accepted()
                    // Let the card go first so the system sheet is what is
                    // on screen when it appears.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        requestReview()
                    }
                } label: {
                    Text("Rate InputConfig")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.solid)
                .keyboardShortcut(.defaultAction)

                Button {
                    review.snoozed()
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.solidSecondary)
                .keyboardShortcut(.cancelAction)

                Button("Don't ask again") { review.declined() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 360)
    }
}

/// The little fun after a rating: a burst of confetti and a thank-you that
/// drifts up and fades. Static text only when Reduce Motion is on.
struct CelebrationOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let start = Date()
    private let pieces: [Piece] = (0..<70).map { _ in Piece() }

    struct Piece {
        let x = Double.random(in: 0...1)
        let delay = Double.random(in: 0...0.5)
        let speed = Double.random(in: 0.55...1.0)
        let drift = Double.random(in: -0.12...0.12)
        let spin = Double.random(in: -6...6)
        let size = CGFloat.random(in: 6...11)
        let color: Color = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .teal].randomElement()!
    }

    var body: some View {
        ZStack {
            if !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(start)
                    Canvas { ctx, size in
                        for p in pieces {
                            let life = (t - p.delay) * p.speed
                            guard life > 0, life < 2.6 else { continue }
                            // Falls with a little sideways drift and fades
                            // out at the end of its life.
                            let y = -20 + life * life * 110 + life * 60
                            let x = (p.x + p.drift * life) * size.width
                            let alpha = life > 2.0 ? max(0, (2.6 - life) / 0.6) : 1
                            var rect = CGRect(x: x, y: y, width: p.size, height: p.size * 0.6)
                            rect = rect.offsetBy(dx: -p.size / 2, dy: 0)
                            var piece = ctx
                            piece.opacity = alpha
                            piece.translateBy(x: rect.midX, y: rect.midY)
                            piece.rotate(by: .radians(life * p.spin))
                            piece.translateBy(x: -rect.midX, y: -rect.midY)
                            piece.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(p.color))
                        }
                    }
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 6) {
                Text("Thank you!")
                    .font(.title.weight(.bold))
                Text("That little push means a lot.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .glassBackground()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thank you. That little push means a lot.")
    }
}

/// Hangs the rating card and the thank-you off the main window. Kept as a
/// modifier so ContentView's already long modifier chain does not grow.
struct ReviewPromptPresenter: ViewModifier {
    @ObservedObject private var review = ReviewPromptService.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $review.showPrompt) {
                ReviewPromptView()
                    .glassBackground()
            }
            .overlay {
                if review.celebrate {
                    CelebrationOverlay()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: review.celebrate)
    }
}
