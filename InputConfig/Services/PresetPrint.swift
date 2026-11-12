import AppKit
import CoreImage
import SwiftUI

/// A preset on paper: its name and notes, its drawing, and what every control
/// does, in black on white whatever the app's appearance. For people who keep
/// a sheet beside the controller, and for helpers setting one up for someone.
@MainActor
enum PresetPrint {
    private static let margin: CGFloat = 40
    /// Where the outputs start on a row, past the control's name.
    private static let column: CGFloat = 170

    private static func page(_ preset: Preset, controllers: GameControllerService) -> (view: NSTextView, info: NSPrintInfo)? {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return nil }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.leftMargin = margin
        info.rightMargin = margin
        info.topMargin = margin
        info.bottomMargin = margin
        let width = max(200, info.paperSize.width - margin * 2)

        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        page.appearance = NSAppearance(named: .aqua)
        page.isEditable = false
        page.drawsBackground = true
        page.backgroundColor = .white
        page.textContainerInset = .zero
        page.textContainer?.lineFragmentPadding = 0
        page.textStorage?.setAttributedString(document(preset, controllers: controllers, width: width))
        if let container = page.textContainer, let layout = page.layoutManager {
            layout.ensureLayout(for: container)
            page.frame.size.height = ceil(layout.usedRect(for: container).height) + 1
        }
        return (page, info)
    }

    static func run(_ preset: Preset, controllers: GameControllerService) {
        guard let made = page(preset, controllers: controllers) else { return }
        let operation = NSPrintOperation(view: made.view, printInfo: made.info)
        operation.jobTitle = preset.name
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    #if DEBUG
    /// The printed page as a PDF, for checking it without a printer.
    static func savePDF(_ preset: Preset, controllers: GameControllerService, to url: URL) {
        guard let made = page(preset, controllers: controllers) else { return }
        made.info.jobDisposition = .save
        made.info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: made.view, printInfo: made.info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }
    #endif

    /// The whole page as text, kept apart from printing so the bench can read it.
    static func document(_ preset: Preset, controllers: GameControllerService?, width: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, after: CGFloat = 6) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = after
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: NSColor.black, .paragraphStyle: style,
            ]))
        }
        add(preset.name, .boldSystemFont(ofSize: 20), after: 2)
        let tag = preset.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty { add(ShippedText.t(tag), .systemFont(ofSize: 12), after: 8) }
        let notes = (preset.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { add(ShippedText.t(notes), .systemFont(ofSize: 11), after: 12) }

        for (slot, joystick) in preset.joysticks.enumerated() where !joystick.bindings.isEmpty {
            if preset.joysticks.count > 1 {
                let name = joystick.tag.trimmingCharacters(in: .whitespacesAndNewlines)
                add(name.isEmpty ? String(localized: "Controller \(slot + 1)") : ShippedText.t(name),
                    .boldSystemFont(ofSize: 14), after: 6)
            }
            if let controllers, let drawing = drawing(preset, slot: slot, controllers: controllers, width: width) {
                let attachment = NSTextAttachment()
                attachment.image = drawing
                let scale = min(1, width / max(1, drawing.size.width))
                attachment.bounds = CGRect(x: 0, y: 0, width: drawing.size.width * scale,
                                           height: drawing.size.height * scale)
                out.append(NSAttributedString(attachment: attachment))
                add("", .systemFont(ofSize: 6), after: 8)
            }
            for row in joystick.bindings {
                out.append(line(for: row, in: preset))
            }
            add("", .systemFont(ofSize: 6), after: 10)
        }
        return out
    }

    /// A row in words: the control, and what it does with its note under that.
    static func summary(of row: BindingModel, in preset: Preset) -> (name: String, does: String) {
        let family = preset.buttonFamily ?? FaceLetters.current
        var name = ButtonNames.inputName(row.input, family: family)
        // A voice row is known by its words.
        if row.input.type == .voicePhrase,
           let phrase = preset.voicePhrases.first(where: { $0.id == row.input.voicePhraseID }) {
            name = phrase.shownName
        }
        if !row.modifiers.isEmpty {
            let held = row.modifiers.map { ButtonNames.inputName($0, family: family) }.joined(separator: " + ")
            name = "\(held) + \(name)"
        }
        var does: [String] = []
        if !row.outputs.isEmpty { does.append(OutputAction.names(row.outputs).joined(separator: " + ")) }
        if let held = row.holdOutputs, !held.isEmpty {
            let what = OutputAction.names(held).joined(separator: " + ")
            does.append(String(localized: "Held: \(what)"))
        }
        if let twice = row.doubleTapOutputs, !twice.isEmpty {
            let what = OutputAction.names(twice).joined(separator: " + ")
            does.append(String(localized: "Double tap: \(what)"))
        }
        if let steps = row.macroSteps, !steps.isEmpty {
            does.append(steps.count == 1 ? String(localized: "Runs a macro of 1 step")
                                         : String(localized: "Runs a macro of \(steps.count) steps"))
        }
        var text = does.joined(separator: ", ")
        let note = ShippedText.t((row.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        // A line separator, not a new paragraph, so the note keeps the
        // printed column's indent.
        if !note.isEmpty { text += text.isEmpty ? note : "\u{2028}" + note }
        return (name, text)
    }

    /// One control on the page: its name, then what it does.
    private static func line(for row: BindingModel, in preset: Preset) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        style.headIndent = column
        style.paragraphSpacing = 5
        let (name, text) = summary(of: row, in: preset)
        let result = NSMutableAttributedString(string: name + "\t", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black, .paragraphStyle: style,
        ])
        result.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black, .paragraphStyle: style,
        ]))
        return result
    }

    /// The drawing's light gray words and lines go dark, or they print faded;
    /// white stays white.
    private static func darkened(_ image: CGImage) -> NSImage {
        let size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let filter = CIFilter(name: "CIGammaAdjust")
        filter?.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter?.setValue(2.6, forKey: "inputPower")
        guard let output = filter?.outputImage,
              let dark = CIContext().createCGImage(output, from: output.extent) else {
            return NSImage(cgImage: image, size: size)
        }
        return NSImage(cgImage: dark, size: size)
    }

    /// The controller drawing in the light appearance with high contrast, on
    /// white. Nil for a slot with nothing to draw.
    static func drawing(_ preset: Preset, slot: Int, controllers: GameControllerService,
                        width: CGFloat) -> NSImage? {
        let view = VirtualControllerView(preset: preset, fixedSlot: slot, trailing: { EmptyView() }, printing: true,
                                         control: VisualizerControlState())
            .environmentObject(controllers)
            .environment(\.colorScheme, .light)
            .environment(\.appHighContrast, true)
            .frame(width: 640)
            .padding(8)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return darkened(image)
    }
}
