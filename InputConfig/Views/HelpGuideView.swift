import SwiftUI

/// Help window. A sidebar of short titles grouped the way the app is
/// organized (getting started, inputs, outputs, row options, controllers,
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
    /// The match count, said once typing pauses.
    @State private var countAnnouncement: DispatchWorkItem?

    private var visibleGuides: [HelpGuide] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HelpGuideLibrary.localizedAll }
        // Search the guide in the app's language, and in English too, so an
        // English term found on the website still finds its guide.
        // Against text lowercased once per launch: lowercasing every guide
        // in two languages on each keystroke stalled the search field.
        return zip(HelpGuideLibrary.localizedAll, zip(Self.searchLocalized, Self.searchEnglish))
            .filter { $0.1.0.contains(q) || (HelpLocalizer.isTranslated && $0.1.1.contains(q)) }.map(\.0)
    }

    private static let searchLocalized: [String] = HelpGuideLibrary.localizedAll.map(\.searchText)
    private static let searchEnglish: [String] = HelpGuideLibrary.all.map(\.searchText)

    private var guidesByCategory: [(category: String, guides: [HelpGuide])] {
        let visible = visibleGuides
        return HelpGuideLibrary.categories.compactMap { category in
            let guides = visible.filter { $0.category == category }
            return guides.isEmpty ? nil : (category, guides)
        }
    }

    private var selectedGuide: HelpGuide? {
        HelpGuideLibrary.localizedAll.first { $0.id == selectedGuideID }
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
                    // The page showing, said: the list's own selection stays
                    // on the last guide behind Overview.
                    .accessibilityAddTraits(showingHome ? .isSelected : [])
                }
                ForEach(guidesByCategory, id: \.category) { group in
                    Section(HelpLocalizer.t(group.category)) {
                        ForEach(group.guides) { guide in
                            Text(guide.title)
                                .tag(guide.id as String?)
                                .accessibilityAddTraits(!showingHome && selectedGuideID == guide.id ? .isSelected : [])
                                // The guide that is already selected behind
                                // Overview opens too: picking it again does
                                // not change the selection.
                                .simultaneousGesture(TapGesture().onEnded {
                                    if selectedGuideID == guide.id { showingHome = false }
                                })
                                .accessibilityAction {
                                    selectedGuideID = guide.id
                                    showingHome = false
                                }
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
                // Never to nil: that collapses the sidebar, search field and all.
                let visible = visibleGuides
                if let id = selectedGuideID,
                   !visible.contains(where: { $0.id == id }),
                   let first = visible.first?.id {
                    selectedGuideID = first
                }
                countAnnouncement?.cancel()
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    let n = visible.count
                    let work = DispatchWorkItem {
                        AccessibilityNotification.Announcement(n == 0 ? String(localized: "No matching guides")
                            : n == 1 ? String(localized: "1 matching guide") : String(localized: "\(n) matching guides")).post()
                    }
                    countAnnouncement = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                }
                // Searching shows the first match rather than leaving
                // Overview up with a match silently selected.
                if !query.trimmingCharacters(in: .whitespaces).isEmpty, !visible.isEmpty { showingHome = false }
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
        #if DEBUG
        // `post inputconfig.debug.help <guide id>` (ContentView) opens the window on that guide.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("inputconfig.debug.helpSelect"))) { note in
            guard let id = note.object as? String else { return }
            query = ""
            if id == "home" { showingHome = true } else { selectedGuideID = id; showingHome = false }
        }
        #endif
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

    /// The window title, centered over the detail column. AppKit's own copy
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
    /// Every searchable word of the guide, lowercased, in one string.
    var searchText: String {
        ([title, intro] + sections.flatMap { [$0.heading] + $0.blocks.map(\.text) }).joined(separator: "\n").lowercased()
    }

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

/// The id the site gives a section heading ("If a pad does nothing" is
/// "if-a-pad-does-nothing"), which is what a link to a section points at.
func helpAnchor(_ heading: String) -> String {
    heading.lowercased()
        .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        .joined(separator: "-")
}

private enum HelpLayout {
    static let column: CGFloat = 640
    static let sectionGap: CGFloat = 28
    static let blockGap: CGFloat = 12
}

// MARK: - One page

private struct HelpPageView: View {
    let guide: HelpGuide
    /// The window's link handler (HelpGuideView), for every link this page
    /// does not take itself.
    @Environment(\.openURL) private var openInWindow

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Title and intro, like the top of a System Settings pane.
                    Text(guide.title)
                        .font(.system(size: 28, weight: .bold))
                        .padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHeading(.h1)
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
                            // The anchor comes from the English heading: links in
                            // every language point at the English slug.
                            .id(helpAnchor(HelpGuideLibrary.all.first { $0.id == guide.id }?
                                .sections[safe: index]?.heading ?? section.heading))
                    }

                    if !guide.related.isEmpty {
                        Divider()
                            .padding(.bottom, 14)
                        Text("Related")
                            .font(.caption.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                        HelpChipRow(links: guide.related)
                            .padding(.bottom, 20)
                    }

                    Text(helpMarkdown(String(localized: "This page on the web: [\(guide.url.replacingOccurrences(of: "https://", with: ""))](\(guide.url))")))
                        .font(.caption)
                        .foregroundStyle(.hint)
                        // Always the browser. The window's handler reads this
                        // page's own address as a link to the page already
                        // showing, so the click did nothing.
                        .environment(\.openURL, OpenURLAction { _ in .systemAction })
                        .accessibilityAction(named: Text("Open This Page on the Web")) {
                            if let url = URL(string: guide.url) { NSWorkspace.shared.open(url) }
                        }
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: HelpLayout.column, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 36)
                .padding(.top, 20)
            }
            // Reachable with Tab, so arrow and Page keys scroll the page
            // and not the sidebar.
            .focusable()
            // A link to a section of this page ("#if-a-pad-does-nothing")
            // scrolls to it. Everything else goes to the window's handler.
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == nil, let anchor = url.fragment, !anchor.isEmpty {
                    proxy.scrollTo(anchor, anchor: .top)
                    return .handled
                }
                openInWindow(url)
                return .handled
            })
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
                .accessibilityHeading(.h2)
                .padding(.bottom, 2)
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                HelpBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HelpBlockView: View {
    @Environment(\.appTextScale) private var textScale
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
                            .frame(width: 150 * max(1, textScale), alignment: .leading)
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
                                // Each cell below says its column instead.
                                .accessibilityHidden(!rows.isEmpty)
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
                                // "Output: Space", so VoiceOver keeps the column.
                                .accessibilityLabel(c < header.count && !header[c].isEmpty
                                    ? String(localized: "\(header[c]): \(String(helpMarkdown(c < row.count ? row[c] : "").characters))")
                                    : String(helpMarkdown(c < row.count ? row[c] : "").characters))
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
                // A Link, not Markdown text: reachable with Tab and Space.
                HelpLinkText(title: link.title, url: link.url)
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
    @Environment(\.appTextScale) private var textScale
    @Environment(\.openURL) private var openURL
    /// A guide's title in the app's language.
    private static func title(_ id: String, _ english: String) -> String {
        HelpGuideLibrary.localizedAll.first { $0.id == id }?.title ?? english
    }
    private let starts: [(title: String, detail: String, id: String)] = [
        (Self.title("first-preset", "Your First Preset"), String(localized: "Connect, activate, grant the one permission. Five minutes."), "first-preset"),
        (Self.title("binding-editor", "The Binding Editor"), String(localized: "What a row is, and every option on it."), "binding-editor"),
        (Self.title("emergency-stop", "Emergency Stop"), String(localized: "The one thing to know before a preset takes the keyboard."), "emergency-stop"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("InputConfig Help")
                    .font(.system(size: 28, weight: .bold))
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h1)
                Text("How each part of the app works, the same pages as on [inputconfig.com](https://inputconfig.com/help/). Pick a topic on the left, or start here.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, HelpLayout.sectionGap)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(starts.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            HelpLinkText(title: item.title, url: "https://inputconfig.com/help/\(item.id)")
                                .font(.body.weight(.semibold))
                                .frame(width: 170 * max(1, textScale), alignment: .leading)
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
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                Text("Longer material that reads better in a browser.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)

                webGroup("Tools", HelpGuideLibrary.tools.map(HelpLocalizer.localized), detail: true)
                webGroup("Accessibility guides", HelpGuideLibrary.accessibilityGuides.map(HelpLocalizer.localized), detail: false)
                webGroup("Work and play guides", HelpGuideLibrary.workAndPlayGuides.map(HelpLocalizer.localized), detail: false)

                Text(helpMarkdown(String(localized: "Also there: a [preset library](https://inputconfig.com/presets/) with a page and a download for every built-in preset and hundreds of Smart Preset Maker layouts, and [short answers](https://inputconfig.com/questions/) to common questions. Feature requests and bugs: [GitHub](https://github.com/ryleighnewman/InputConfig). About this app: [here](inputconfig://about).")))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // Links inside text are not reached with Tab; each one
                    // is an action on the paragraph too.
                    .accessibilityActions {
                        Button("Preset Library") { openURL(URL(string: "https://inputconfig.com/presets/")!) }
                        Button("Short Answers") { openURL(URL(string: "https://inputconfig.com/questions/")!) }
                        Button("GitHub") { openURL(URL(string: "https://github.com/ryleighnewman/InputConfig")!) }
                        Button("About This App") { openURL(URL(string: "inputconfig://about")!) }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: HelpLayout.column, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 36)
            .padding(.top, 20)
        }
        // Reachable with Tab, so arrow and Page keys scroll the page and
        // not the sidebar, as on the guide pages.
        .focusable()
    }

    @ViewBuilder
    private func webGroup(_ title: LocalizedStringKey, _ links: [HelpWebLink], detail: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h3)
        if detail {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(links, id: \.url) { link in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        HelpLinkText(title: link.title, url: link.url)
                            .font(.body.weight(.medium))
                            .frame(width: 170 * max(1, textScale), alignment: .leading)
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

    /// Opened by the Quick Start tour, which closes it again; a Help window
    /// that was already open stays.
    private var openedForTour = false

    func showForTour() {
        if window?.isVisible != true { openedForTour = true }
        show()
    }

    func closeForTour() {
        guard openedForTour else { return }
        openedForTour = false
        window?.close()
    }

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingController(rootView: HelpGuideView()
            .windowBackdrop()
            .reduceMotionFriendly()
            .appAccessibility())
        let newWindow = HelpWindow(contentViewController: hosting)
        newWindow.title = String(localized: "Help")
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

/// The title is drawn centered by the view's toolbar. AppKit's own copy
/// would sit at the leading edge of the detail column, and the split view
/// turns it back on whenever the selection changes, so the window refuses
/// to show it at all. The title itself stays for the Window menu.
private final class HelpWindow: NSWindow {
    override var titleVisibility: NSWindow.TitleVisibility {
        get { .hidden }
        set { super.titleVisibility = .hidden }
    }
}

/// A Help link the keyboard can reach: a SwiftUI Link styled like the
/// Markdown links around it (the window's openURL handler still decides
/// whether it opens in Help or in the browser).
private struct HelpLinkText: View {
    let title: String
    let url: String

    var body: some View {
        if let target = URL(string: url) {
            Link(title, destination: target)
                .buttonStyle(.link)
                // A title that wraps lines up at the left, not centered.
                .multilineTextAlignment(.leading)
                .focusable()
        } else {
            Text(title)
        }
    }
}
