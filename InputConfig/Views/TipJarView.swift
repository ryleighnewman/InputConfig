import SwiftUI
import StoreKit

/// Lets a user send a tip via Apple's In-App Purchase system. Two paths are
/// offered: a one-time consumable tip, or a monthly auto-renewing tip.
/// Both are processed entirely by StoreKit so the app stays compliant with
/// guideline 3.1.1; there are no external payment links anywhere in the app.
struct TipJarView: View {
    @StateObject private var service = TipJarService.shared
    @State private var showingThanks = false
    @State private var recurring = false
    @State private var isRestoring = false
    @Environment(\.dismiss) private var dismiss

    /// Deep link the App Store uses for the subscription management screen.
    /// `manageSubscriptionsSheet` is iOS-only, so on macOS we hand off to the
    /// App Store via NSWorkspace.
    private static let manageSubscriptionsURL = URL(string: "macappstore://apps.apple.com/account/subscriptions")!

    /// Terms of Use (EULA) and Privacy Policy links required in the app for
    /// auto-renewable subscriptions (Guideline 3.1.2). The Terms link uses the
    /// standard Apple EULA; the Privacy link must match the Privacy Policy URL
    /// set in App Store Connect.
    private static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyPolicyURL = URL(string: "https://github.com/ryleighnewman/InputConfig/blob/main/PRIVACY.md")!

    var body: some View {
        VStack(spacing: 16) {
            header

            Divider()

            recurringToggle

            if service.isLoading {
                ProgressView("Loading tip options...")
                    .padding(.vertical, 40)
            } else if displayedProducts.isEmpty {
                emptyState
            } else {
                productList
            }

            if recurring {
                subscriptionDisclosure
            }

            Divider()

            footer
        }
        .frame(width: 480)
        .padding(20)
        .task { await service.loadProducts() }
        .alert("Thank you!", isPresented: $showingThanks) {
            Button("You're welcome", role: .cancel) {}
        } message: {
            Text("Your support means a lot. InputConfig will keep getting better because of it.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 36))
                .foregroundStyle(.pink)
            Text("Support InputConfig")
                .font(.title2.weight(.semibold))
            Text("InputConfig is free forever. If it makes your setup better, a tip helps fund continued development.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Transparent breakdown of where the money actually goes.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.pink.opacity(0.7))
                    .font(.caption2)
                Text("Tips are completely optional. InputConfig is free with no locked features. Tips simply support continued development and future updates.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.pink.opacity(0.2), lineWidth: 0.5)
            )
            .padding(.top, 4)
        }
    }

    // MARK: - Recurring Toggle

    private var recurringToggle: some View {
        HStack {
            Toggle(isOn: $recurring) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make this recurring monthly")
                        .font(.body)
                    Text(recurring
                         ? "Tips charge automatically each month until cancelled."
                         : "Switch on to support monthly instead of one time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Product List

    private var displayedProducts: [Product] {
        recurring ? service.subscriptionProducts : service.consumableProducts
    }

    private var productList: some View {
        VStack(spacing: 10) {
            ForEach(displayedProducts, id: \.id) { product in
                productRow(product)
            }
        }
    }

    @ViewBuilder
    private func productRow(_ product: Product) -> some View {
        Button {
            Task { await tip(product) }
        } label: {
            HStack(spacing: 12) {
                tierIcon(for: product.id)
                    .font(.title3)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if service.purchaseInProgress == product.id {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 90, alignment: .trailing)
                } else {
                    Text(priceLabel(for: product))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(service.purchaseInProgress != nil)
    }

    private func priceLabel(for product: Product) -> String {
        if product.type == .autoRenewable {
            return "\(product.displayPrice)/mo"
        }
        return product.displayPrice
    }

    @ViewBuilder
    private func tierIcon(for productID: String) -> some View {
        // The icon is chosen by tier so order matches the displayed price,
        // for both consumable and subscription variants.
        if productID.contains(".small") {
            Image(systemName: "cup.and.saucer.fill")
                .foregroundStyle(.brown)
        } else if productID.contains(".medium") {
            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                .foregroundStyle(.orange)
        } else if productID.contains(".large") {
            Image(systemName: "fork.knife")
                .foregroundStyle(.purple)
        } else {
            Image(systemName: "gift.fill")
                .foregroundStyle(.pink)
        }
    }

    // MARK: - Subscription Disclosure

    private var subscriptionDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Subscription auto-renews monthly at the listed price. Cancel anytime in your App Store account. Payment is charged to your Apple ID at confirmation of purchase.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            legalLinks
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Functional Terms of Use (EULA) and Privacy Policy links. Required in the
    /// purchase flow for auto-renewable subscriptions; shown in the subscription
    /// disclosure and the footer so they are always reachable.
    private var legalLinks: some View {
        HStack(spacing: 14) {
            Link("Terms of Use (EULA)", destination: Self.termsOfUseURL)
            Link("Privacy Policy", destination: Self.privacyPolicyURL)
        }
        .font(.caption2)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if service.totalTipsCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "hands.sparkles.fill")
                        .foregroundStyle(.yellow)
                    Text("You've tipped \(service.totalTipsCount) time\(service.totalTipsCount == 1 ? "" : "s"). Thank you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                HStack {
                    Text("Payments are processed by Apple.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }

            HStack {
                legalLinks
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    Task { await restore() }
                } label: {
                    if isRestoring {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .disabled(isRestoring)

                if service.activeSubscription != nil {
                    Button("Manage Subscription") {
                        NSWorkspace.shared.open(Self.manageSubscriptionsURL)
                    }
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.circle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Tips are temporarily unavailable")
                .font(.subheadline)
            Text("Please try again in a moment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await service.loadProducts() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(.vertical, 30)
    }

    // MARK: - Purchase

    private func tip(_ product: Product) async {
        do {
            let succeeded = try await service.purchase(product)
            if succeeded { showingThanks = true }
        } catch {
            // Errors are surfaced through service.lastError
            await service.loadProducts()
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        await service.restorePurchases()
    }
}

/// Shows the tip jar in a standalone window so it can be opened from menu commands.
@MainActor
final class TipJarWindowController {
    static let shared = TipJarWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: TipJarView())
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Support InputConfig"
        newWindow.setContentSize(NSSize(width: 520, height: 640))
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
