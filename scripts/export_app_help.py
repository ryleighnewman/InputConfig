#!/usr/bin/env python3
"""Generate InputConfig/Resources/HelpGuides.swift from the inputconfig.com help pages.

The site's content/help-*.json files are the one source for how the app's systems
work. This turns them into the in-app Help library so the two never drift:

  python3 scripts/export_app_help.py

Reads ~/Desktop/Apps/inputconfig.com/content (override with $IC_SITE). HTML becomes
ordered blocks (paragraphs, lists, term lists, tables, questions) with Markdown
links; relative links become absolute inputconfig.com links. The in-app pages use
short titles and their own grouping (below), not the site's SEO headlines. The
use-case guides and tools are listed on the Help home page as links only.
"""
import json, os, re, html as htmlmod, glob, sys

SITE = os.environ.get("IC_SITE", os.path.expanduser("~/Desktop/Apps/inputconfig.com"))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "InputConfig", "Resources", "HelpGuides.swift")
BASE = "https://inputconfig.com"

# In-app title and category for every site page, in sidebar order.
# (site slug, short title, category)
PAGES = [
    ("help/first-preset", "Your First Preset", "Getting started"),
    ("help/connecting-controllers", "Connecting a Controller", "Getting started"),
    ("help/binding-editor", "The Binding Editor", "Getting started"),
    ("help/scan-to-bind", "Scan", "Getting started"),
    ("help/presets-and-folders", "Presets and Folders", "Getting started"),
    ("help/built-in-presets", "Built-in Presets", "Getting started"),
    ("help/smart-preset-maker", "Smart Preset Maker", "Getting started"),

    ("help/keyboard-and-mouse-as-input", "Keyboard, Mouse, Trackpad", "Inputs"),
    ("help/midi-as-input", "MIDI Devices", "Inputs"),
    ("help/gyroscope-aim", "Gyroscope", "Inputs"),
    ("help/touchpad-as-mouse", "Touchpad as a Mouse", "Inputs"),
    ("help/touchpad-regions-and-gestures", "Touchpad Zones", "Inputs"),
    ("help/cursor-and-stick-regions", "Screen Regions, Stick Zones", "Inputs"),
    ("help/tap-the-mac", "Tap the Mac", "Inputs"),

    ("help/system-functions", "System Functions", "Outputs"),
    ("help/dictation-zoom-speak", "Dictation and Zoom", "Outputs"),
    ("help/midi-output", "MIDI Output", "Outputs"),
    ("help/one-stick-driving", "One-Stick Driving", "Outputs"),

    ("help/chords", "Chords", "Row options"),
    ("help/hold-and-double-tap", "Hold and Double-Tap", "Row options"),
    ("help/macros-turbo-and-toggle", "Macros, Turbo, Toggle", "Row options"),
    ("help/deadzones-and-sensitivity", "Deadzones", "Row options"),
    ("help/variable-sensitivity", "Variable Sensitivity", "Row options"),
    ("help/haptic-feedback", "Vibration", "Row options"),
    ("help/spoken-feedback", "Spoken Feedback", "Row options"),

    ("help/dualsense-edge", "DualSense Edge", "Controllers"),
    ("help/light-bar", "Light Bar", "Controllers"),
    ("help/switch-pro-controller", "Switch Pro Controller", "Controllers"),
    ("help/joy-cons", "Joy-Cons", "Controllers"),
    ("help/8bitdo-controllers", "8BitDo", "Controllers"),
    ("help/stadia-controller", "Stadia Controller", "Controllers"),
    ("help/steam-controller", "Steam Controller", "Controllers"),
    ("help/access-controller-no-input", "Access Controller", "Controllers"),
    ("help/other-controllers", "Other Controllers", "Controllers"),

    ("help/live-visualizer", "Live Visualizer", "The app"),
    ("help/per-app-auto-switch", "Auto-Switch", "The app"),
    ("help/emergency-stop", "Emergency Stop", "The app"),
    ("help/menu-bar", "Menu Bar", "The app"),
    ("help/settings", "Settings", "The app"),
    ("help/statistics", "Statistics", "The app"),
    ("help/data-and-backups", "Data and Backups", "The app"),
    ("help/accessibility-features", "Accessibility", "The app"),
]
CATEGORIES = ["Getting started", "Inputs", "Outputs", "Row options", "Controllers", "The app"]

# Sections that are about the site or the pitch, not about using the app.
DROP_SECTIONS = {"Why it exists"}
# Site tools that add nothing inside the app (the app's own Anki preset
# already does what the Anki add-on does).
DROP_TOOLS = {"tools/anki-spacebar-binder", "tools/key-code-finder", "tools/controller-map", "tools/deadzone-visualizer"}


def load(pattern):
    pages = []
    for f in sorted(glob.glob(os.path.join(SITE, "content", pattern))):
        pages += json.load(open(f))
    return pages


help_pages = {p["slug"]: p for p in load("help-*.json")}
guide_pages = []
for f in sorted(glob.glob(os.path.join(SITE, "content", "guides-*.json"))):
    group = os.path.basename(f)[len("guides-"):-len(".json")]
    for p in json.load(open(f)):
        p.setdefault("group", group)
        guide_pages.append(p)

missing = [s for s, _, _ in PAGES if s not in help_pages]
extra = [s for s in help_pages if s not in {p[0] for p in PAGES}]
if missing or extra:
    sys.exit("page list out of date: missing %s, unlisted %s" % (missing, extra))

short_title = {s: t for s, t, _ in PAGES}
titles = dict(short_title)
titles.update({p["slug"]: p["h1"] for p in guide_pages})
tool_desc = {}
for f in glob.glob(os.path.join(SITE, "tools", "*.html")):
    slug = "tools/" + os.path.basename(f)[:-5]
    if slug == "tools/index":
        continue
    page = open(f).read()
    m = re.search(r"<h1[^>]*>([^<]*)</h1>", page)
    titles[slug] = htmlmod.unescape(m.group(1).strip()) if m else slug
    m = re.search(r'name="description" content="([^"]*)"', page)
    tool_desc[slug] = htmlmod.unescape(m.group(1)) if m else ""


def title_for(slug):
    if slug in titles:
        return titles[slug]
    if slug.startswith("presets/"):
        name = slug.rsplit("/", 1)[-1].replace("-", " ").title()
        return name.replace("Midi", "MIDI").replace("Daw", "DAW").replace("Fps", "FPS").replace("Ps5", "PS5") + " preset"
    return slug


# ---------------------------------------------------------------- HTML -> blocks
def absolute(href):
    return BASE + href if href.startswith("/") else href


def inline(s):
    s = re.sub(r'<a\s+href="([^"]+)"[^>]*>(.*?)</a>', lambda m: "[%s](%s)" % (inline(m.group(2)), absolute(m.group(1))), s, flags=re.S)
    s = re.sub(r"<strong>(.*?)</strong>", r"**\1**", s, flags=re.S)
    s = re.sub(r"<em>(.*?)</em>", r"_\1_", s, flags=re.S)
    s = re.sub(r"<[^>]+>", "", s)
    s = htmlmod.unescape(s)
    return re.sub(r"\s+", " ", s).strip()


TAG = r"(?:\s[^>]*)?"


def blocks(h):
    """A section's HTML as an ordered list of (kind, payload)."""
    out = []
    pattern = re.compile(r"<(p|ul|ol|dl|table)%s>(.*?)</\1>" % TAG, re.S)
    for m in pattern.finditer(h):
        tag, body = m.group(1), m.group(2)
        if tag == "p":
            t = inline(body)
            if t:
                out.append(("p", t))
        elif tag in ("ul", "ol"):
            items = [inline(li) for li in re.findall(r"<li%s>(.*?)</li>" % TAG, body, flags=re.S)]
            out.append(("ol" if tag == "ol" else "ul", items))
        elif tag == "dl":
            pairs = [(inline(dt), inline(dd)) for dt, dd in re.findall(r"<dt%s>(.*?)</dt>\s*<dd%s>(.*?)</dd>" % (TAG, TAG), body, flags=re.S)]
            out.append(("dl", pairs))
        elif tag == "table":
            header = [inline(c) for c in re.findall(r"<th%s>(.*?)</th>" % TAG, body, flags=re.S)]
            rows = []
            for r in re.findall(r"<tr%s>(.*?)</tr>" % TAG, body, flags=re.S):
                cells = [inline(c) for c in re.findall(r"<td%s>(.*?)</td>" % TAG, r, flags=re.S)]
                if cells:
                    rows.append(cells)
            out.append(("table", (header, rows)))
    return out


def swift_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def swift_block(kind, payload, pad):
    if kind == "p":
        return pad + ".paragraph(%s)" % swift_str(payload)
    if kind in ("ul", "ol"):
        items = ",\n".join(pad + "    " + swift_str(i) for i in payload)
        return pad + ".list([\n%s\n%s], ordered: %s)" % (items, pad, "true" if kind == "ol" else "false")
    if kind == "dl":
        items = ",\n".join(pad + "    HelpTerm(term: %s, detail: %s)" % (swift_str(t), swift_str(d)) for t, d in payload)
        return pad + ".terms([\n%s\n%s])" % (items, pad)
    if kind == "table":
        header, rows = payload
        hdr = "[" + ", ".join(swift_str(c) for c in header) + "]"
        rws = ",\n".join(pad + "    [" + ", ".join(swift_str(c) for c in r) + "]" for r in rows)
        return pad + ".table(header: %s, rows: [\n%s\n%s])" % (hdr, rws, pad)
    if kind == "qa":
        items = ",\n".join(pad + "    HelpQuestion(question: %s, answer: %s)" % (swift_str(q), swift_str(a)) for q, a in payload)
        return pad + ".questions([\n%s\n%s])" % (items, pad)
    raise ValueError(kind)


# ---------------------------------------------------------------- build
out = []
out.append("import Foundation\n")
out.append("// Generated by scripts/export_app_help.py from the inputconfig.com help pages.\n// Edit the site's content/help-*.json (or the title table in the script) and re-run.\n")
out.append('''
/// One help page: a site page, with the app's own short title and grouping.
struct HelpGuide: Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    /// The same page on inputconfig.com.
    let url: String
    /// One short paragraph under the title.
    let intro: String
    let sections: [HelpSection]
    /// Other pages worth reading next: (title, url). In-app help pages open
    /// in the window; anything else opens the site.
    let related: [HelpLink]
}

struct HelpSection: Hashable {
    let heading: String
    let blocks: [HelpBlock]
}

struct HelpTerm: Hashable {
    let term: String
    let detail: String
}

struct HelpQuestion: Hashable {
    let question: String
    let answer: String
}

struct HelpLink: Hashable {
    let title: String
    let url: String
}

/// Page content in document order. Strings are Markdown (links, bold).
enum HelpBlock: Hashable {
    case paragraph(String)
    case list([String], ordered: Bool)
    case terms([HelpTerm])
    case table(header: [String], rows: [[String]])
    case questions([HelpQuestion])
}

/// A page on inputconfig.com that is not mirrored in the app.
struct HelpWebLink: Hashable {
    let title: String
    let detail: String
    let url: String
}

enum HelpGuideLibrary {
    static let site = "https://inputconfig.com"
    static let categories: [String] = [%s]
''' % ", ".join(swift_str(c) for c in CATEGORIES))

guide_vars = []
for slug, title, category in PAGES:
    p = help_pages[slug]
    gid = slug.split("/", 1)[1]
    var = "g_" + re.sub(r"[^a-z0-9]", "_", gid)
    guide_vars.append(var)
    intro_blocks = [b for b in blocks(p["intro"]) if b[0] == "p"]
    intro = intro_blocks[0][1] if intro_blocks else inline(p["description"])
    sections = []
    # The site's step list, as an ordered list at the top: the app used
    # to get every page without its steps.
    if p.get("howto_steps"):
        sections.append(("Steps", [("ol", [inline(x) for x in p["howto_steps"]])]))
    for s in p["sections"]:
        if s["heading"] in DROP_SECTIONS:
            continue
        bl = blocks(s["html"])
        if not bl:
            sys.exit("EMPTY SECTION %s / %s: %s" % (slug, s["heading"], s["html"][:120]))
        sections.append((s["heading"], bl))
    if p.get("faq"):
        sections.append(("Questions", [("qa", [(inline(q["q"]), inline(q["a"])) for q in p["faq"]])]))
    related = [(title_for(r), BASE + "/" + r) for r in p.get("related", []) if r != slug]

    out.append("\n    static let %s = HelpGuide(\n" % var)
    out.append("        id: %s,\n" % swift_str(gid))
    out.append("        title: %s,\n" % swift_str(title))
    out.append("        category: %s,\n" % swift_str(category))
    out.append("        url: %s,\n" % swift_str(BASE + "/" + slug))
    out.append("        intro: %s,\n" % swift_str(intro))
    out.append("        sections: [\n")
    for heading, bl in sections:
        out.append("            HelpSection(heading: %s, blocks: [\n" % swift_str(heading))
        out.append(",\n".join(swift_block(k, v, " " * 16) for k, v in bl) + "\n")
        out.append("            ]),\n")
    out.append("        ],\n")
    out.append("        related: [\n" + "".join("            HelpLink(title: %s, url: %s),\n" % (swift_str(t), swift_str(u)) for t, u in related) + "        ]\n")
    out.append("    )\n")

out.append("\n    static let all: [HelpGuide] = [\n" + "".join("        %s,\n" % v for v in guide_vars) + "    ]\n")


def links(pages):
    return "[\n" + "".join("        HelpWebLink(title: %s, detail: %s, url: %s),\n" % (
        swift_str(p["h1"]), swift_str(inline(p["description"])), swift_str(BASE + "/" + p["slug"])) for p in pages) + "    ]\n"


access = sorted([p for p in guide_pages if p["group"] == "access"], key=lambda p: p["order"])
work = sorted([p for p in guide_pages if p["group"] == "work"], key=lambda p: p["order"])
out.append("\n    /// Longer walkthroughs on the site, one per situation. Not mirrored here.\n")
out.append("    static let accessibilityGuides: [HelpWebLink] = " + links(access))
out.append("    static let workAndPlayGuides: [HelpWebLink] = " + links(work))
question_pages = sorted(load("questions-*.json"), key=lambda p: p["order"])
out.append("\n    /// Short answers on the site, one question each. Not mirrored here.\n")
out.append("    static let questions: [HelpWebLink] = " + links(question_pages))
tools = sorted((k, v) for k, v in tool_desc.items() if k not in DROP_TOOLS)
out.append("\n    /// Interactive references on the site.\n    static let tools: [HelpWebLink] = [\n" + "".join(
    "        HelpWebLink(title: %s, detail: %s, url: %s),\n" % (swift_str(titles.get(s, s)), swift_str(d), swift_str(BASE + "/" + s)) for s, d in tools) + "    ]\n")
out.append("}\n")

open(OUT, "w").write("".join(out))
print("wrote", os.path.relpath(OUT), "-", len(PAGES), "guides,", len(access) + len(work), "web guides,", len(question_pages), "questions,", len(tools), "tools")
