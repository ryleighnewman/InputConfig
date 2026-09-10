import SwiftUI

/// Help Guide window. A sidebar of categorized tutorials on the left,
/// the selected guide rendered on the right. Add new guides via
/// `HelpGuideLibrary.all` in HelpGuides.swift.
struct HelpGuideView: View {
    /// MUST stay non-nil. A nil selection collapses the NavigationSplitView
    /// sidebar on macOS: the search field disappears, the list scrolls to its
    /// last section, and the rows draw up under the traffic lights. So "show
    /// the home page" is tracked separately rather than by clearing this.
    @State private var selectedGuideID: String? = HelpGuideLibrary.all.first?.id
    /// The window opens on the intro page, which stands on its own rather
    /// than being stacked above a guide.
    @State private var showingHome = true
    @State private var query = ""

    /// Guides whose title, summary, or any section text contains the query.
    private var visibleGuides: [HelpGuide] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HelpGuideLibrary.all }
        return HelpGuideLibrary.all.filter { guide in
            guide.title.lowercased().contains(q)
            || guide.summary.lowercased().contains(q)
            || guide.sections.contains { sec in
                sec.heading.lowercased().contains(q)
                || sec.body.lowercased().contains(q)
                || sec.steps.contains { $0.lowercased().contains(q) }
            }
        }
    }

    private var guidesByCategory: [(category: String, guides: [HelpGuide])] {
        let grouped = Dictionary(grouping: visibleGuides, by: \.category)
        return grouped
            .map { (category: $0.key, guides: $0.value) }
            .sorted { $0.category < $1.category }
    }

    private var selectedGuide: HelpGuide? {
        HelpGuideLibrary.all.first { $0.id == selectedGuideID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedGuideID) {
                Section {
                    // A Button, not a tagged row: selection has to stay on a
                    // real guide (see selectedGuideID).
                    Button {
                        showingHome = true
                    } label: {
                        Label("Home", systemImage: "house")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(showingHome ? Color.accentColor : .primary)
                }
                ForEach(guidesByCategory, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.guides) { guide in
                            Text(guide.title)
                                .tag(guide.id as String?)
                        }
                    }
                }
            }
            .navigationTitle("Help Guides")
            .searchable(text: $query, placement: .sidebar, prompt: "Search guides")
            .onChange(of: selectedGuideID) { _, _ in
                // Picking a guide leaves the home page.
                showingHome = false
            }
            .onChange(of: query) { _, _ in
                // Keep something readable selected while filtering.
                if let id = selectedGuideID,
                   !visibleGuides.contains(where: { $0.id == id }) {
                    selectedGuideID = visibleGuides.first?.id
                }
            }
            .frame(minWidth: 240)
        } detail: {
            Group {
                if showingHome {
                    helpHome
                } else if let guide = selectedGuide {
                    guideDetail(guide)
                } else {
                    helpHome
                }
            }
            // Content dissolves into the window vibrancy under the transparent
            // titlebar, matching the main window (spec section 3).
            .headerFade()
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 820, minHeight: 540)
    }

    @ViewBuilder
    private func guideDetail(_ guide: HelpGuide) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                // Centered, calm header: big title,
                // secondary summary. Reads like an Apple settings page.
                VStack(spacing: 6) {
                    Text(guide.title)
                        .font(.largeTitle.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(guide.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 10)

                ForEach(guide.sections, id: \.heading) { section in
                    sectionView(section)
                }

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        // Static title, applied on the same view the working version used. An
        // empty split-view toolbar collapses the sidebar's titlebar inset.
        .navigationTitle("Help")
    }

    /// The page the window opens on. Stands by itself rather than sitting
    /// above a guide, so it reads as a front door instead of a banner.
    /// The About link cannot be a plain URL because it opens a sheet in
    /// another window, so it uses a private scheme intercepted below.
    private var helpHome: some View {
        ScrollView {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("InputConfig Help")
                .font(.largeTitle.weight(.semibold))
            // A markdown link inside Text rather than a Link view: Link is a
            // focusable control, so it grabbed initial keyboard focus when the
            // window opened and drew a ring that read as a stray box around
            // the domain. focusEffectDisabled does not suppress it.
            Text("[inputconfig.com](https://inputconfig.com)")
                .font(.callout.weight(.semibold))
            Text("Browse the guides on the left for short articles on everything the app does.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            Text("This help guide is intended to help with common problems in the app. If you have a feature request, please reach out to the developer directly or check out [GitHub](https://github.com/ryleighnewman/InputConfig). You can view information about the app [here](inputconfig://about).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        }
        .navigationTitle("Help")
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "inputconfig", url.host == "about" else {
                return .systemAction
            }
            MenuBarController.shared.openAboutPage()
            return .handled
        })
    }

    /// Each guide section is one quiet glass card. Steps are plain
    /// Apple-style numbered lines - no badges, no accent ink, no inner
    /// panels - so the content is the loudest thing on the page.
    @ViewBuilder
    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(section.heading)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if !section.body.isEmpty {
                Text(section.body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.steps.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1).")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            Text(step)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardPad + 2)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }
}

/// Standalone window controller helper so the Help Guides view can be shown
/// from anywhere via NSWindow rather than a Scene.
@MainActor
final class HelpGuideWindowController {
    static let shared = HelpGuideWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: HelpGuideView()
            .background(VisualEffectBackground().ignoresSafeArea())
            .reduceMotionFriendly())
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Help"
        newWindow.setContentSize(NSSize(width: 880, height: 580))
        // .fullSizeContentView lets the behind-window blur reach under the
        // transparent titlebar; without it the titlebar shows straight through
        // to the desktop (the "completely transparent top bar" bug).
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
