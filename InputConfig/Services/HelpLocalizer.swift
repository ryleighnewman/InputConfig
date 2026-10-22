import Foundation
import SwiftUI

/// The in-app Help in the app's language. The guides are generated in
/// English (Resources/HelpGuides.swift, from the website's help pages); each
/// translation is a table from an English string to its translation, one
/// file per language in the bundle's HelpTranslations folder
/// (help-<language>.json). A string with no translation stays English, so a
/// guide edited after its translation still reads, partly in English, until
/// the table catches up.
enum HelpLocalizer {
    /// The table for the language the app is showing, loaded once.
    private static let table: [String: String] = {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        guard lang != "en",
              let folder = Bundle.main.url(forResource: "HelpTranslations", withExtension: nil),
              let data = try? Data(contentsOf: folder.appendingPathComponent("help-\(lang).json")),
              let t = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return t
    }()

    /// One string in the app's language.
    static func t(_ s: String) -> String { table[s] ?? s }

    static var isTranslated: Bool { !table.isEmpty }

    /// The website's folder for the app's language: its questions and
    /// guides are translated under /de/, /fr/ and so on. Help and preset
    /// pages, and the section indexes, are English only.
    private static let siteLanguage: String? = siteFolder(for: Bundle.main.preferredLocalizations.first ?? "en")

    /// The website's folder for an app language; nil for English.
    static func siteFolder(for lang: String) -> String? {
        switch lang {
        case "en": return nil
        case "pt-BR": return "pt"
        case "zh-Hans": return "zh"
        case "zh-Hant": return "zh-tw"
        default: return lang
        }
    }

    /// Pages the website has in English only.
    private static let englishOnlyPages: Set<String> = ["mac-games-with-controller-support"]

    /// An inputconfig.com question or guide in the app's language; any
    /// other address is returned as it is.
    static func siteURL(_ url: URL) -> URL { siteURL(url, folder: siteLanguage) }

    static func siteURL(_ url: URL, folder: String?) -> URL {
        guard let lang = folder, url.host == "inputconfig.com" else { return url }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, ["questions", "guides"].contains(parts[0]),
              !englishOnlyPages.contains(parts[1]),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.path = "/\(lang)/\(parts[0])/\(parts[1])"
        return c.url ?? url
    }

    static func localized(_ g: HelpGuide) -> HelpGuide {
        guard isTranslated else { return g }
        return HelpGuide(id: g.id, title: t(g.title), category: g.category, url: g.url, intro: t(g.intro),
                         sections: g.sections.map { s in
                             HelpSection(heading: t(s.heading), blocks: s.blocks.map(localized))
                         },
                         related: g.related.map { HelpLink(title: t($0.title), url: $0.url) })
    }

    static func localized(_ b: HelpBlock) -> HelpBlock {
        switch b {
        case .paragraph(let p): return .paragraph(t(p))
        case .list(let items, let ordered): return .list(items.map(t), ordered: ordered)
        case .terms(let terms): return .terms(terms.map { HelpTerm(term: t($0.term), detail: t($0.detail)) })
        case .table(let header, let rows): return .table(header: header.map(t), rows: rows.map { $0.map(t) })
        case .questions(let qs): return .questions(qs.map { HelpQuestion(question: t($0.question), answer: t($0.answer)) })
        }
    }

    static func localized(_ w: HelpWebLink) -> HelpWebLink {
        HelpWebLink(title: t(w.title), detail: t(w.detail), url: w.url)
    }

    /// Every English string the Help shows, for the translation tables.
    static func allStrings() -> [String] {
        var out: [String] = []
        func add(_ s: String) { if !s.isEmpty { out.append(s) } }
        HelpGuideLibrary.categories.forEach(add)
        for g in HelpGuideLibrary.all {
            add(g.title); add(g.intro)
            g.related.forEach { add($0.title) }
            for s in g.sections {
                add(s.heading)
                for b in s.blocks {
                    switch b {
                    case .paragraph(let p): add(p)
                    case .list(let items, _): items.forEach(add)
                    case .terms(let ts): ts.forEach { add($0.term); add($0.detail) }
                    case .table(let h, let rows): h.forEach(add); rows.forEach { $0.forEach(add) }
                    case .questions(let qs): qs.forEach { add($0.question); add($0.answer) }
                    }
                }
            }
        }
        for w in HelpGuideLibrary.accessibilityGuides + HelpGuideLibrary.workAndPlayGuides + HelpGuideLibrary.tools {
            add(w.title); add(w.detail)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

extension HelpGuideLibrary {
    /// The guides in the app's language.
    static let localizedAll: [HelpGuide] = all.map(HelpLocalizer.localized)
}

extension Array {
    /// The element at `index`, or nil past either end.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The text InputConfig ships in its built-in presets and the Smart Preset
/// Maker library (preset names, tags, folder names, row notes, subtitles), in
/// the app's language. Presets keep their English text on disk; a string is
/// translated on screen only when it is exactly the shipped English, so
/// anything a person wrote or edited shows as they wrote it.
enum ShippedText {
    private static let table: [String: String] = {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        guard lang != "en",
              let folder = Bundle.main.url(forResource: "HelpTranslations", withExtension: nil),
              let data = try? Data(contentsOf: folder.appendingPathComponent("presets-\(lang).json")),
              let t = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return t
    }()

    static func t(_ s: String) -> String { table[s] ?? s }

    /// The phrases the built-in presets speak. Only these are spoken and
    /// shown translated: a phrase someone typed that happens to match a
    /// shipped string ("open", "Back") is theirs and stays as typed.
    @MainActor static let shippedPhrases: Set<String> = Set(ExamplePresets.all.flatMap { p in
        p.joysticks.flatMap { $0.bindings.compactMap(\.speechText) }
    })

    /// A row's phrase as it is spoken and shown.
    @MainActor static func phrase(_ s: String) -> String { shippedPhrases.contains(s) ? t(s) : s }

    /// The shipped English a shown translation stands for, so text typed
    /// back to exactly a translation ("Carreras" after an edit undone by
    /// hand) is stored as the English built-in it is.
    /// Built from the shipped preset names, then their tags, in a fixed
    /// order, so it never depends on which row note shares a translation.
    private static let reverse: [String: String] = {
        guard !table.isEmpty else { return [:] }
        let shipped = ExamplePresets.all
        var r: [String: String] = [:]
        for english in shipped.map(\.name).sorted() + shipped.map(\.tag).sorted() {
            if let shown = table[english], r[shown] == nil { r[shown] = english }
        }
        return r
    }()

    static func english(for shown: String) -> String? { reverse[shown] }

    /// The same for any shipped text (notes, row notes, group descriptions),
    /// in a fixed order: an edit undone back to the shown translation is
    /// stored as the English it shows.
    private static let reverseAll: [String: String] = {
        var r: [String: String] = [:]
        for english in table.keys.sorted() where r[table[english]!] == nil { r[table[english]!] = english }
        return r
    }()

    static func englishText(for shown: String) -> String? { reverseAll[shown] }

    /// A name or tag as shown: the shipped table, and the placeholder tag a
    /// new preset gets.
    static func shown(_ s: String) -> String { s == "No tag" ? String(localized: "No tag") : t(s) }

    /// The stored form of text shown by `shown(_:)`.
    static func stored(_ shownText: String) -> String {
        if shownText == String(localized: "No tag") { return "No tag" }
        return english(for: shownText) ?? shownText
    }
}

/// The words on the controller drawings (control names such as "Right
/// trackpad", their notes, why a control is dark), in the app's language,
/// from HelpTranslations/layouts-<language>.json. The layouts keep their
/// English; a string with no translation stays English.
enum LayoutText {
    private static let table: [String: String] = {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        guard lang != "en",
              let folder = Bundle.main.url(forResource: "HelpTranslations", withExtension: nil),
              let data = try? Data(contentsOf: folder.appendingPathComponent("layouts-\(lang).json")),
              let t = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return t
    }()

    static func t(_ s: String) -> String { table[s] ?? s }
}

extension Preset {
    /// The name and tag as shown. A built-in preset keeps its English on
    /// disk (matching, seeding and backups find it by that), and shows it in
    /// the app's language; a name a person wrote shows as written.
    var shownName: String { ShippedText.t(name) }
    var shownTag: String { ShippedText.shown(tag) }
}

extension Binding where Value == String {
    /// A field that shows a built-in text in the app's language and writes
    /// only what the person changes, so opening the editor never turns a
    /// built-in name into its translation on disk.
    /// The same for longer shipped text (preset notes, a group's
    /// description): shown translated, written only when changed.
    static func shippedText(_ base: Binding<String>) -> Binding<String> {
        Binding(get: { ShippedText.t(base.wrappedValue) },
                set: { if $0 != ShippedText.t(base.wrappedValue) { base.wrappedValue = ShippedText.englishText(for: $0) ?? $0 } })
    }

    static func shipped(_ base: Binding<String>) -> Binding<String> {
        Binding(get: { ShippedText.shown(base.wrappedValue) },
                set: { if $0 != ShippedText.shown(base.wrappedValue) { base.wrappedValue = ShippedText.stored($0) } })
    }
}

extension TouchpadRegion {
    /// The name as shown: a built-in preset's region ("Undo", "Top left
    /// corner") in the app's language, a name a person gave as written.
    var shownName: String { ShippedText.t(name) }
}

extension ControllerLayout {
    /// The model's name as shown: product names stay as they are, generic
    /// ones ("Standard gamepad", "Arcade stick") in the app's language.
    var shownName: String { LayoutText.t(displayName) }
}

extension String {
    /// Without the right-to-left mark that Arabic and Hebrew translations
    /// open with, for text that is measured, cut, or put inside other text
    /// (a key chord, a stored name, a file name).
    var withoutRTLMark: String { hasPrefix("\u{200F}") ? String(dropFirst()) : self }
}

import SwiftUI

extension View {
    /// The names Voice Control answers to, the word on the control first:
    /// "click Save" works when the VoiceOver label says more ("Save preset").
    func voiceNames(_ names: LocalizedStringKey...) -> some View {
        accessibilityInputLabels(names.map { Text($0) })
    }
}

extension View {
    /// Escape runs `action` too (a sheet whose Done button only has Return).
    /// An invisible button behind this view, outside the layout and
    /// accessibility, so nothing on screen changes.
    func closesOnEscape(_ action: @escaping () -> Void) -> some View {
        background(
            Button("", action: action)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}
