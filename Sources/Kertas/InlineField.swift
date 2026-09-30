import AppKit
import PDFKit

/// A text box laid over the page while you type: for Edit Text and Add Text.
/// Return keeps what you typed, Esc throws it away, clicking elsewhere keeps it.
final class InlineField: NSObject, NSTextFieldDelegate {
    private let field = NSTextField()
    private var done: ((String?) -> Void)?

    init(canvas: Canvas, page: PDFPage, rect: NSRect, text: String, font: NSFont, color: NSColor,
         minWidth: CGFloat, done: @escaping (String?) -> Void) {
        self.done = done
        super.init()
        guard let host = canvas.documentView else { return }
        let onScreen = host.convert(canvas.convert(rect, from: page), from: canvas)
        let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * canvas.scaleFactor) ?? font
        let height = ceil(scaled.ascender - scaled.descender + scaled.leading) + 8

        field.font = scaled
        field.stringValue = text
        field.textColor = color
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.96)
        field.drawsBackground = true
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .exterior
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.frame = NSRect(x: onScreen.minX - 4, y: onScreen.midY - height / 2,
                             width: max(onScreen.width + 80, minWidth), height: height)
        host.addSubview(field)
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finish(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish() }

    func finish() { close(with: field.stringValue) }
    func cancel() { close(with: nil) }

    private func close(with value: String?) {
        guard let done else { return }
        self.done = nil
        let window = field.window
        DispatchQueue.main.async { self.field.removeFromSuperview() }
        if let pdfView = field.superview?.enclosingScrollView?.superview { window?.makeFirstResponder(pdfView) }
        done(value)
    }
}

enum Fonts {
    /// The font file for a font named inside a PDF, when this Mac has that font
    /// as a single .ttf or .otf. PyMuPDF can embed those; font collections
    /// (.ttc) it can't, and the helper falls back to the nearest built-in font.
    static func file(named name: String) -> String? {
        guard let font = NSFont(name: name, size: 12),
              font.fontName.caseInsensitiveCompare(name) == .orderedSame
                || font.fontName.replacingOccurrences(of: "-", with: "").caseInsensitiveCompare(name.replacingOccurrences(of: "-", with: "")) == .orderedSame,
              let url = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL,
              ["ttf", "otf"].contains(url.pathExtension.lowercased()) else { return nil }
        return url.path
    }

    /// The font to show in the edit box: the real one if installed, otherwise a
    /// look-alike with the same weight and slant.
    static func screenFont(named name: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        if let exact = NSFont(name: name, size: size) { return exact }
        let lower = name.lowercased()
        let family = lower.contains("times") || lower.contains("serif") && !lower.contains("sans") ? "Times New Roman"
            : lower.contains("courier") || lower.contains("mono") ? "Courier New" : "Helvetica"
        var traits: NSFontTraitMask = []
        if bold || lower.contains("bold") { traits.insert(.boldFontMask) }
        if italic || lower.contains("italic") || lower.contains("oblique") { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: size)
            ?? .systemFont(ofSize: size)
    }
}
