import SwiftUI
import StoreKit

/// Calls the system review sheet when ReviewPromptService asks for it. The
/// sheet is Apple's own, the only in-app way to leave a rating; the app adds
/// no card of its own in front of it. Kept as a modifier on the main window
/// because `requestReview` comes from the SwiftUI environment.
struct ReviewPromptPresenter: ViewModifier {
    @ObservedObject private var review = ReviewPromptService.shared
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content
            .onChange(of: review.reviewRequest) { _, _ in
                requestReview()
            }
    }
}
