import SwiftUI

/// Help window. A sidebar of short titles grouped the way the app is
/// organised (getting started, inputs, outputs, row options, controllers,
/// the app), and on the right one page rendered as a document: a title, one
/// intro line, sections with a clear heading and their content in order,
/// numbered steps, term lists, tables, and a Questions section. Content is
/// generated from the inputconfig.com help pages (HelpGuides.swift).
struct HelpGuideView: View {
    /// MUST stay non-nil. A nil selection collapses the NavigationSplitView
    /// sidebar on macOS: the search field disappears, the list scrolls to its
    /// last section, and the rows draw up under the traffic lights. So "show
    /// the home page" is tracked separately rather than by clearing this.
    @State private var selectedGuideID: String? = HelpGuideLibrary.all.first?.id
    @State private var showingHome = true
    @State private var query = ""

    private var visibleGuides: [HelpGuide] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HelpGuideLibrary.all }
        return HelpGuideLibrary.all.filter { $0.matches(q) }
    }

    private var guidesByCategory: [(category: String, guides: [HelpGuide])] {
        HelpGuideLibrary.categories.compactMap { category in
            let guides = visibleGuides.filter { $0.category == category }
            return guides.isEmpty ? nil : (category, guides)
        }
    }

    private var selectedGuide: HelpGuide? {
        HelpGuideLibrary.all.first { $0.id == selectedGuideID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedGuideID) {
                Section {
                    Button {
                        showingHome = true
                    } label: {
                        Label("Overview", systemImage: "house")
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
            .navigationTitle("")
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .onChange(of: selectedGuideID) { _, _ in
                showingHome = false
            }
            .onChange(of: query) { _, _ in
                if let id = selectedGuideID,
                   !visibleGuides.contains(where: { $0.id == id }) {
                    selectedGuideID = visibleGuides.first?.id
                }
            }
            .frame(minWidth: 220)
        } detail: {
            Group {
                if showingHome {
                    HelpHomePage()
                } else if let guide = selectedGuide {
                    HelpPageView(guide: guide)
                        .id(guide.id)
                } else {
                    HelpHomePage()
                }
            }
            .headerFade()
            .toolbar { centeredTitle }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 860, minHeight: 560)
        // Links between help pages stay in the window; everything else
        // (guides, tools, presets, About) goes where it points.
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "inputconfig", url.host == "about" {
                MenuBarController.shared.openAboutPage()
                return .handled
            }
            if url.host == "inputconfig.com" {
                let parts = url.path.split(separator: "/").map(String.init)
                if parts.count == 2, parts[0] == "help",
                   HelpGuideLibrary.all.contains(where: { $0.id == parts[1] }) {
                    query = ""
                    selectedGuideID = parts[1]
                    showingHome = false
                    return .handled
                }
            }
            return .systemAction
        })
    }

    /// The window title, centerd over the detail column. AppKit's own copy
    /// is suppressed by HelpWindow. A non-empty toolbar also keeps the
    /// sidebar's titlebar inset, which an empty one collapses.
    @ToolbarContentBuilder
    private var centeredTitle: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .principal) {
                Text("Help").font(.headline)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                Text("Help").font(.headline)
            }
        }
    }
}

extension HelpGuide {
    func matches(_ q: String) -> Bool {
        if title.lowercased().contains(q) || intro.lowercased().contains(q) { return true }
        return sections.contains { section in
            section.heading.lowercased().contains(q) || section.blocks.contains { $0.text.lowercased().contains(q) }
        }
    }
}

extension HelpBlock {
    /// Plain text of the block, for search.
    var text: String {
        switch self {
        case .paragraph(let s): return s
        case .list(let items, _): return items.joined(separator: " ")
        case .terms(let terms): return terms.map { $0.term + " " + $0.detail }.joined(separator: " ")
        case .table(let header, let rows): return (header + rows.flatMap { $0 }).joined(separator: " ")
        case .questions(let qs): return qs.map { $0.question + " " + $0.answer }.joined(separator: " ")
        }
    }
}

// MARK: - Shared text helpers

/// Markdown (links, bold) to an attributed string; plain text if it does
/// not parse.
func helpMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

private enum HelpLayout {
    static let column: CGFloat = 640
    static let sectionGap: CGFloat = 28
    static let blockGap: CGFloat = 12
}

// MARK: - One page

private struct HelpPageView: View {
    let guide: HelpGuide

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Title and intro, like the top of a System Settings pane.
                Text(guide.title)
                    .font(.system(size: 28, weight: .bold))
                    .padding(.bottom, 8)
                Text(helpMarkdown(guide.intro))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, HelpLayout.sectionGap)

                ForEach(Array(guide.sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 {
                        Divider()
                            .padding(.bottom, HelpLayout.sectionGap - 6)
                    }
                    HelpSectionView(section: section)
                        .padding(.bottom, HelpLayout.sectionGap - 6)
                }

                if !guide.related.isEmpty {
                    Divider()
                        .padding(.bottom, 14)
                    Text("Related")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    HelpChipRow(links: guide.related)
                        .padding(.bottom, 20)
                }

                Text(helpMarkdown("This page on the web: [\(guide.url.replacingOccurrences(of: "https://", with: ""))](\(guide.url))"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: HelpLayout.column, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 36)
            .padding(.top, 20)
        }
    }
}

private struct HelpSectionView: View {
    let section: HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: HelpLayout.blockGap) {
            Text(section.heading)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                HelpBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(helpMarkdown(text))
                .font(.body)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if ordered {
                            Text("\(index + 1)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
                        } else {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 5, height: 5)
                                .frame(width: 20)
                                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
                        }
                        Text(helpMarkdown(item))
                            .font(.body)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)

        case .terms(let terms):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(terms.enumerated()), id: \.offset) { index, term in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(helpMarkdown(term.term))
                            .font(.body.weight(.semibold))
                            .frame(width: 150, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(helpMarkdown(term.detail))
                            .font(.body)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                    if index < terms.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

        case .table(let header, let rows):
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            Text(c < header.count ? header[c] : "")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                    }
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            Text(helpMarkdown(c < row.count ? row[c] : ""))
                                .font(.body)
                                .padding(.vertical, 6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index < rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

        case .questions(let questions):
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(helpMarkdown(q.question))
                            .font(.body.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(helpMarkdown(q.answer))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Wrapped row of link chips.
private struct HelpChipRow: View {
    let links: [HelpLink]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(links, id: \.url) { link in
                Text(helpMarkdown("[\(link.title)](\(link.url))"))
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
    }
}

/// Minimal wrapping layout for chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Overview page

/// The page the window opens on: where to start, then the material that
/// stays on the site (situation guides and interactive tools) as links.
private struct HelpHomePage: View {
    private let starts: [(title: String, detail: String, id: String)] = [
        ("Your First Preset", "Connect, activate, grant the one permission. Five minutes.", "first-preset"),
        ("The Binding Editor", "What a row is, and every option on it.", "binding-editor"),
        ("Emergency Stop", "The one thing to know before a preset takes the keyboard.", "emergency-stop"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("InputConfig Help")
                    .font(.system(size: 28, weight: .bold))
                    .padding(.bottom, 8)
                Text("How each part of the app works, the same pages as on [inputconfig.com](https://inputconfig.com/help/). Pick a topic on the left, or start here.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, HelpLayout.sectionGap)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(starts.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(helpMarkdown("[\(item.title)](https://inputconfig.com/help/\(item.id))"))
                                .font(.body.weight(.semibold))
                                .frame(width: 170, alignment: .leading)
                            Text(item.detail)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 9)
                        if index < starts.count - 1 { Divider().opacity(0.5) }
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .padding(.bottom, HelpLayout.sectionGap)

                Divider().padding(.bottom, HelpLayout.sectionGap - 6)
                Text("On inputconfig.com")
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 4)
                Text("Longer material that reads better in a browser.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)

                webGroup("Tools", HelpGuideLibrary.tools, detail: true)
                webGroup("Accessibility guides", HelpGuideLibrary.accessibilityGuides, detail: false)
                webGroup("Work and play guides", HelpGuideLibrary.workAndPlayGuides, detail: false)

                Text(helpMarkdown("Also there: a [preset library](https://inputconfig.com/presets/) with a page and a download for every built-in preset and hundreds of Smart Preset Maker layouts, and [short answers](https://inputconfig.com/questions/) to common questions. Feature requests and bugs: [GitHub](https://github.com/ryleighnewman/InputConfig). About this app: [here](inputconfig://about)."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: HelpLayout.column, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 36)
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private func webGroup(_ title: String, _ links: [HelpWebLink], detail: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
        if detail {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(links, id: \.url) { link in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(helpMarkdown("[\(link.title)](\(link.url))"))
                            .font(.body.weight(.medium))
                            .frame(width: 170, alignment: .leading)
                        Text(link.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 18)
        } else {
            HelpChipRow(links: links.map { HelpLink(title: $0.title, url: $0.url) })
                .padding(.bottom, 18)
        }
    }
}

// MARK: - Window

/// Standalone window controller helper so the Help view can be shown from
/// anywhere via NSWindow rather than a Scene.
@MainActor
final class HelpGuideWindowController {
    static let shared = HelpGuideWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingController(rootView: HelpGuideView()
            .background(VisualEffectBackground().ignoresSafeArea())
            .reduceMotionFriendly()
            .appAccessibility())
        let newWindow = HelpWindow(contentViewController: hosting)
        newWindow.title = "Help"
        newWindow.setContentSize(NSSize(width: 960, height: 640))
        // .fullSizeContentView lets the behind-window blur reach under the
        // transparent titlebar; without it the titlebar shows straight through
        // to the desktop (the "completely transparent top bar" bug).
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The title is drawn centred by the view's toolbar. AppKit's own copy
/// would sit at the leading edge of the detail column, and the split view
/// turns it back on whenever the selection changes, so the window refuses
/// to show it at all. The title itself stays for the Window menu.
private final class HelpWindow: NSWindow {
    override var titleVisibility: NSWindow.TitleVisibility {
        get { .hidden }
        set { super.titleVisibility = .hidden }
    }
}
