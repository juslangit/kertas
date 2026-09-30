import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Turning other files into PDF pages, and PDF pages into pictures.
enum Convert {
    static let wordTypes: [UTType] = ["docx", "doc", "rtf", "odt"].compactMap { UTType(filenameExtension: $0) }
    static var importableTypes: [UTType] { [.pdf, .image, .plainText, .html] + wordTypes }

    static let a4 = NSRect(x: 0, y: 0, width: 595, height: 842)

    /// The pages a file would add: a PDF's own pages, one page per picture, or a
    /// Word/RTF/text file laid out on A4.
    static func pages(from url: URL) -> [PDFPage] {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url) else { return [] }
            return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.copy() as? PDFPage }
        }
        if type?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return [] }
            return page(for: image).map { [$0] } ?? []
        }
        guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil),
              let data = pdfData(from: text), let doc = PDFDocument(data: data) else { return [] }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0) }
    }

    /// Lays styled text out on A4 pages with the Mac's own text system, one
    /// text frame per page, and draws each frame onto its own PDF page. The words
    /// stay real text. Good for letters and reports; complex Word layouts
    /// (floating pictures, text boxes) come out simplified.
    static func pdfData(from text: NSAttributedString) -> Data? {
        let margin: CGFloat = 56
        let frame = a4.insetBy(dx: margin, dy: margin)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var frames: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: frame.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            frames.append(container)
            let range = layout.glyphRange(for: container)
            // A frame that takes nothing (a picture taller than a page) would loop forever.
            if range.length == 0 && frames.count > 1 { break }
        } while NSMaxRange(layout.glyphRange(for: frames.last!)) < layout.numberOfGlyphs && frames.count < 5000

        return drawPDF(pages: frames.count, size: a4.size) { index, context in
            // The text system draws top-down, PDF is bottom-up.
            context.translateBy(x: 0, y: a4.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let range = layout.glyphRange(for: frames[index])
            layout.drawBackground(forGlyphRange: range, at: NSPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: range, at: NSPoint(x: margin, y: margin))
        }
    }

    /// A picture as one A4 page, turned to landscape for wide pictures and
    /// scaled to fill the page without stretching.
    static func page(for image: NSImage) -> PDFPage? {
        let landscape = image.size.width > image.size.height
        let size = landscape ? NSSize(width: a4.height, height: a4.width) : a4.size
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        let data = drawPDF(pages: 1, size: size) { _, context in
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: rect)
        }
        return data.flatMap(PDFDocument.init(data:))?.page(at: 0)
    }

    private static func drawPDF(pages: Int, size: NSSize, draw: (Int, CGContext) -> Void) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            context.saveGState()
            draw(index, context)
            context.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A page drawn as a picture at the given resolution, turned the way it's shown.
    static func bitmap(of page: PDFPage, dpi: CGFloat) -> NSBitmapImageRep? {
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        let scale = dpi / 72
        let pixels = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width),
                                         pixelsHigh: Int(pixels.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: pixels).fill()
        // The thumbnail is what handles rotation and draws the annotations.
        page.thumbnail(of: pixels, for: .cropBox).draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

/// Reading text off scanned pages with Apple's Vision framework, on this Mac.
enum OCR {
    struct Job {
        let page: Int
        let image: CGImage
        let box: NSRect
        let rotation: Int
    }

    /// For each page, the lines found and where they sit in PDF space.
    static func recognise(_ jobs: [Job]) -> [[String: Any]] {
        jobs.compactMap { job in
            // Accurate mode fails outright on some macOS builds (this Mac, macOS 27,
            // 2026-09-30: an e5rt error from the ML runtime, CPU or not), while
            // fast mode works. Try accurate, fall back to fast, never to nothing.
            guard let request = [VNRequestTextRecognitionLevel.accurate, .fast].lazy
                .compactMap({ read(job.image, level: $0) }).first else { return nil }
            let lines: [[String: Any]] = (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string,
                      !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                let b = observation.boundingBox
                let corners = [unrotate(b.minX, b.minY, job.rotation), unrotate(b.maxX, b.maxY, job.rotation)]
                let xs = corners.map(\.x), ys = corners.map(\.y)
                return ["text": text, "rect": [
                    job.box.minX + xs.min()! * job.box.width, job.box.minY + ys.min()! * job.box.height,
                    job.box.minX + xs.max()! * job.box.width, job.box.minY + ys.max()! * job.box.height,
                ]]
            }
            return lines.isEmpty ? nil : ["page": job.page, "lines": lines]
        }
    }

    private static func read(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        request.recognitionLanguages = ["en-US", "ms-MY"].filter(supported.contains)
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request
        } catch {
            return nil
        }
    }

    /// Vision measures on the picture as shown; the text layer is written on the
    /// page as stored. For a page turned by `rotation` degrees clockwise, this
    /// maps a point on the picture (0–1, origin bottom-left) back to the page.
    private static func unrotate(_ u: CGFloat, _ v: CGFloat, _ rotation: Int) -> CGPoint {
        switch (rotation % 360 + 360) % 360 {
        case 90: CGPoint(x: 1 - v, y: u)
        case 180: CGPoint(x: 1 - u, y: 1 - v)
        case 270: CGPoint(x: v, y: 1 - u)
        default: CGPoint(x: u, y: v)
        }
    }
}
