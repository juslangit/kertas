import AppKit
import PDFKit
import UniformTypeIdentifiers

/// One window, one PDF.
///
/// Undo works by snapshot: before anything changes the document, `checkpoint`
/// keeps a copy of the whole file. That one rule covers everything — an
/// annotation added by PDFKit, a line rewritten by the Python helper, a page
/// moved — without each tool writing its own undo.
final class EditorController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let canvas = Canvas()
    let sidebar = Sidebar()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "Open a PDF (⌘O), or drop one here.\nDrop images or Word files to turn them into a PDF.")
    private let toolControl = NSSegmentedControl()
    private let colorWell = NSColorWell(style: .minimal)
    private let textSizePopup = NSPopUpButton()
    private let penPopup = NSPopUpButton()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .init("search"))
    private var activeField: InlineField?
    private var busy = false

    var fileURL: URL? { didSet { updateChrome() } }
    var dirty = false { didSet { window?.isDocumentEdited = dirty } }
    var pdf: PDFDocument? { canvas.document }
    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }

    var inkColor: NSColor { colorWell.color }
    var textSize: CGFloat { CGFloat(textSizePopup.selectedTag()) }
    var lineWidth: CGFloat { CGFloat(penPopup.selectedTag()) }

    var currentIndex: Int {
        guard let doc = pdf, let page = canvas.currentPage else { return 0 }
        return doc.index(for: page)
    }

    // MARK: Window

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 420)
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("KertasEditor")
        super.init(window: window)
        window.delegate = self
        canvas.editor = self
        sidebar.editor = self
        buildLayout()
        buildToolbar()
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: canvas)
        updateChrome()
        if let offset = (NSApp.delegate as? AppDelegate)?.editors.count, offset > 0 {
            window.center()
            window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat(offset * 24),
                                          y: window.frame.minY - CGFloat(offset * 24)))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        let content = DropView()
        content.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        window?.contentView = content

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        let stage = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.unregisterDraggedTypes()   // drops go to the window, which knows what to do with them
        stage.addSubview(canvas)
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: stage.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
        ])

        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(stage)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for label in [statusLabel, pageLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [spinner, statusLabel, NSView(), pageLabel])
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(split)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            split.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 26),
        ])
        DispatchQueue.main.async { split.setPosition(180, ofDividerAt: 0) }
    }

    func updateChrome() {
        window?.title = displayName
        window?.representedURL = fileURL
        let hasDoc = pdf != nil
        emptyLabel.isHidden = hasDoc
        sidebar.isHidden = !hasDoc
        toolControl.isEnabled = hasDoc
        if let doc = pdf {
            pageLabel.stringValue = "Page \(currentIndex + 1) of \(doc.pageCount)"
        } else {
            pageLabel.stringValue = ""
        }
    }

    @objc private func pageChanged() {
        updateChrome()
        sidebar.showCurrent(currentIndex)
    }

    func status(_ text: String) { statusLabel.stringValue = text }

    private func setBusy(_ message: String?) {
        busy = message != nil
        if let message { status(message); spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Toolbar

    private enum Item {
        static let tools = NSToolbarItem.Identifier("tools")
        static let color = NSToolbarItem.Identifier("color")
        static let textSize = NSToolbarItem.Identifier("textSize")
        static let pen = NSToolbarItem.Identifier("pen")
        static let zoom = NSToolbarItem.Identifier("zoom")
    }

    private func buildToolbar() {
        toolControl.segmentCount = Tool.allCases.count
        toolControl.trackingMode = .selectOne
        for tool in Tool.allCases {
            toolControl.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: tool.rawValue)
            toolControl.setToolTip("\(tool.title)  (⌘\(tool.rawValue + 1))", forSegment: tool.rawValue)
            toolControl.setWidth(34, forSegment: tool.rawValue)
        }
        toolControl.selectedSegment = 0
        toolControl.target = self
        toolControl.action = #selector(toolSegment(_:))

        colorWell.color = .black
        colorWell.toolTip = "Colour for text and drawing"

        for size in [9, 10, 11, 12, 14, 16, 18, 24, 32, 48] {
            textSizePopup.addItem(withTitle: "\(size) pt")
            textSizePopup.lastItem?.tag = size
        }
        textSizePopup.selectItem(withTag: 12)
        textSizePopup.toolTip = "Size of text you add"
        for width in [1, 2, 3, 5, 8] {
            penPopup.addItem(withTitle: "Pen \(width)")
            penPopup.lastItem?.tag = width
        }
        penPopup.selectItem(withTag: 2)
        penPopup.toolTip = "Thickness of lines you draw"

        searchItem.searchField.sendsWholeSearchString = true
        searchItem.searchField.placeholderString = "Find in PDF"
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(search(_:))

        let toolbar = NSToolbar(identifier: "KertasToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.tools, Item.color, Item.textSize, Item.pen, .flexibleSpace, Item.zoom, searchItem.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == searchItem.itemIdentifier { return searchItem }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Item.tools: item.view = toolControl; item.label = "Tools"
        case Item.color: item.view = colorWell; item.label = "Colour"
        case Item.textSize: item.view = textSizePopup; item.label = "Text Size"
        case Item.pen: item.view = penPopup; item.label = "Pen"
        case Item.zoom:
            let zoom = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom out")!,
                NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom in")!,
            ], trackingMode: .momentary, target: self, action: #selector(zoomSegment(_:)))
            item.view = zoom
            item.label = "Zoom"
        default: return nil
        }
        return item
    }

    @objc private func toolSegment(_ sender: NSSegmentedControl) {
        setTool(Tool(rawValue: sender.selectedSegment) ?? .select)
    }

    @objc private func zoomSegment(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? canvas.zoomOut(nil) : canvas.zoomIn(nil)
    }

    // MARK: Loading and undo

    func load(data: Data, keepPlace: Bool) {
        guard let doc = PDFDocument(data: data) else { return }
        let index = currentIndex
        let autoScales = canvas.autoScales, scale = canvas.scaleFactor
        let clip = canvas.documentView?.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        activeField?.cancel()

        canvas.document = doc
        if keepPlace {
            canvas.autoScales = autoScales
            if !autoScales { canvas.scaleFactor = scale }
            if let page = doc.page(at: min(index, doc.pageCount - 1)) { canvas.go(to: page) }
            if let origin, let scroll = canvas.documentView?.enclosingScrollView {
                DispatchQueue.main.async {
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
        sidebar.reload()
        sidebar.showCurrent(currentIndex)
        updateChrome()
    }

    /// Call before changing the document. Keeps a copy of it for Undo.
    func checkpoint(_ name: String) {
        guard let data = pdf?.dataRepresentation() else { return }
        registerRestore(data, name)
        dirty = true
    }

    private func registerRestore(_ data: Data, _ name: String) {
        guard let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { me in
            // Registering again while undoing is what makes Redo work.
            if let now = me.pdf?.dataRepresentation() { me.registerRestore(now, name) }
            me.load(data: data, keepPlace: true)
            me.dirty = true
        }
        undo.setActionName(name)
    }

    /// Runs a helper command on the current document and shows its result.
    /// The document goes out as in.pdf and comes back as out.pdf.
    func transform(_ name: String, busy message: String,
                   _ args: @escaping (_ input: String, _ output: String) -> [String],
                   done: (([String: Any]) -> Void)? = nil) {
        guard !busy, let before = pdf?.dataRepresentation() else { return }
        let dir = Helper.scratch()
        let input = dir.appendingPathComponent("in.pdf"), output = dir.appendingPathComponent("out.pdf")
        do { try before.write(to: input) } catch {
            showError("Couldn't prepare the file: \(error.localizedDescription)", in: window)
            return
        }
        setBusy(message)
        Helper.run(args(input.path, output.path)) { [weak self] result in
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let self else { return }
            self.setBusy(nil)
            switch result {
            case .success(let json):
                // Nothing was changed (e.g. no highlight where you clicked): keep
                // the document as it is and add nothing to Undo.
                if (json["changed"] as? Bool) == false {
                    self.status("")
                    done?(json)
                    return
                }
                guard let data = try? Data(contentsOf: output) else {
                    showError("The helper finished but wrote no file.", in: self.window)
                    return
                }
                self.registerRestore(before, name)
                self.dirty = true
                self.load(data: data, keepPlace: true)
                self.status("")
                done?(json)
            case .failure(let failure):
                self.status("")
                showError(failure.message, in: self.window)
            }
        }
    }

    /// PDFKit's own rectangle, as the four numbers the helper expects.
    private func numbers(_ r: NSRect) -> [String] {
        [r.minX, r.minY, r.maxX, r.maxY].map { String(format: "%.3f", $0) }
    }

    // MARK: Tools

    func setTool(_ tool: Tool) {
        activeField?.finish()
        canvas.tool = tool
        toolControl.selectedSegment = tool.rawValue
        if pdf != nil { status(tool.hint) }
    }

    @objc func chooseTool(_ sender: NSMenuItem) {
        setTool(Tool(rawValue: sender.tag) ?? .select)
    }

    /// Edit Text: find the line under the click, ask the helper what font it is
    /// set in, and put a text box over it in that font.
    func beginEditText(on page: PDFPage, at point: NSPoint) {
        guard !busy, let doc = pdf else { return }
        guard let line = page.selectionForLine(at: point),
              !(line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status("There's no text there. Click on a line of text.")
            return
        }
        let rect = line.bounds(for: page)
        let index = doc.index(for: page)
        guard let data = doc.dataRepresentation() else { return }
        let dir = Helper.scratch()
        let input = dir.appendingPathComponent("in.pdf")
        try? data.write(to: input)
        setBusy("Reading the line…")
        Helper.run(["span-info", input.path, "\(index)"] + numbers(rect)) { [weak self] result in
            try? FileManager.default.removeItem(at: dir)
            guard let self else { return }
            self.setBusy(nil)
            switch result {
            case .failure(let failure):
                self.status(failure.message)
            case .success(let info):
                let original = info["text"] as? String ?? line.string ?? ""
                let fontName = info["font"] as? String ?? "Helvetica"
                let size = CGFloat(info["size"] as? Double ?? 12)
                let rgb = (info["color"] as? [Double]) ?? [0, 0, 0]
                let colour = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
                let font = Fonts.screenFont(named: fontName, size: size,
                                            bold: info["bold"] as? Bool ?? false,
                                            italic: info["italic"] as? Bool ?? false)
                self.status("Editing a line in \(fontName), \(Int(size.rounded())) pt. Return saves, Esc cancels.")
                self.activeField = InlineField(canvas: self.canvas, page: page, rect: rect, text: original,
                                               font: font, color: colour, minWidth: 160) { [weak self] newText in
                    guard let self, let newText, newText != original else { return }
                    let fontFile = Fonts.file(named: fontName) ?? ""
                    self.transform("Edit Text", busy: "Rewriting the line…", { i, o in
                        ["edit-text", i, o, "\(index)"] + self.numbers(rect) + [newText, fontFile]
                    }, done: { json in
                        let used = json["font"] as? String ?? ""
                        self.status(fontFile.isEmpty
                            ? "Line rewritten. \(fontName) isn't installed on this Mac, so the closest built-in font (\(used)) was used."
                            : "Line rewritten in \(fontName).")
                    })
                }
            }
        }
    }

    /// Add Text, or change text added earlier (a FreeText annotation).
    func beginAddText(on page: PDFPage, at point: NSPoint, editing existing: PDFAnnotation?) {
        let font = existing?.font ?? NSFont(name: "Helvetica", size: textSize) ?? .systemFont(ofSize: textSize)
        let colour = existing?.fontColor ?? inkColor
        let rect = existing?.bounds
            ?? NSRect(x: point.x, y: point.y - font.pointSize * 1.2, width: 10, height: font.pointSize * 1.2)
        activeField = InlineField(canvas: canvas, page: page, rect: rect, text: existing?.contents ?? "",
                                  font: font, color: colour, minWidth: 220) { [weak self] text in
            guard let self, let text else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let existing {
                guard trimmed != existing.contents else { return }
                self.checkpoint(trimmed.isEmpty ? "Delete Text" : "Change Text")
                if trimmed.isEmpty {
                    page.removeAnnotation(existing)
                    self.canvas.selectAnnotation(nil)
                } else {
                    existing.contents = trimmed
                    existing.bounds = Self.textBounds(trimmed, font: font, topLeft: NSPoint(x: rect.minX, y: rect.maxY))
                    self.canvas.selectAnnotation((existing, page))
                }
                return
            }
            guard !trimmed.isEmpty else { return }
            self.checkpoint("Add Text")
            let note = PDFAnnotation(bounds: Self.textBounds(trimmed, font: font, topLeft: NSPoint(x: rect.minX, y: rect.maxY)),
                                     forType: .freeText, withProperties: nil)
            note.contents = trimmed
            note.font = font
            note.fontColor = colour
            note.color = .clear
            let border = PDFBorder()
            border.lineWidth = 0
            note.border = border
            page.addAnnotation(note)
        }
    }

    private static func textBounds(_ text: String, font: NSFont, topLeft: NSPoint) -> NSRect {
        let size = (text as NSString).size(withAttributes: [.font: font])
        let width = size.width + 10, height = size.height + 4
        return NSRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height)
    }

    func highlight(_ selection: PDFSelection) {
        checkpoint("Highlight")
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let box = line.bounds(for: page)
                guard box.width > 0, box.height > 0 else { continue }
                let mark = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
                mark.color = NSColor.systemYellow.withAlphaComponent(0.5)
                // Other PDF readers draw a highlight from these corners, not from the bounds.
                mark.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: box.height)), NSValue(point: NSPoint(x: box.width, y: box.height)),
                    NSValue(point: .zero), NSValue(point: NSPoint(x: box.width, y: 0)),
                ]
                page.addAnnotation(mark)
            }
        }
    }

    /// Removes the highlight under a click: one added as an annotation (by
    /// Kertas or another reader), or else one printed into the page, which the
    /// helper deletes as a shape while leaving the text on it.
    func removeHighlight(on page: PDFPage, at point: NSPoint) {
        if let mark = page.annotations.last(where: { $0.type == "Highlight" && $0.bounds.contains(point) }) {
            checkpoint("Remove Highlight")
            page.removeAnnotation(mark)
            status("Highlight removed.")
            return
        }
        guard let doc = pdf else { return }
        let index = doc.index(for: page)
        transform("Remove Highlight", busy: "Removing the highlight…", { i, o in
            ["remove-mark", i, o, "\(index)", String(format: "%.3f", point.x), String(format: "%.3f", point.y)]
        }, done: { json in
            self.status((json["removed"] as? Int ?? 0) > 0
                ? "Highlight removed. The text on it is untouched."
                : "There's no highlight there. Drag across text to add one.")
        })
    }

    @objc func removeAllHighlights(_ sender: Any?) {
        guard pdf != nil else { return }
        transform("Remove All Highlights", busy: "Removing highlights…", { i, o in ["remove-marks", i, o] },
                  done: { json in
            let printed = json["removed"] as? Int ?? 0
            // Annotations come back in the reloaded document, so look them up again there.
            guard let now = self.pdf else { return }
            let marks = (0..<now.pageCount).flatMap { i in
                now.page(at: i).map { page in page.annotations.filter { $0.type == "Highlight" }.map { (page, $0) } } ?? []
            }
            if printed == 0 && !marks.isEmpty { self.checkpoint("Remove All Highlights") }
            for (page, mark) in marks { page.removeAnnotation(mark) }
            let total = printed + marks.count
            self.status(total == 0 ? "This PDF has no highlights."
                : "Removed \(total) highlight\(total == 1 ? "" : "s"). The text is untouched.")
        })
    }

    /// Adds pen strokes as one ink annotation. The paths arrive in page space.
    @discardableResult
    func addInk(_ paths: [NSBezierPath], on page: PDFPage, color: NSColor? = nil,
                width: CGFloat? = nil, name: String = "Draw") -> PDFAnnotation? {
        guard !paths.isEmpty else { return nil }
        let w = width ?? lineWidth
        let box = paths.map(\.bounds).reduce(paths[0].bounds) { $0.union($1) }.insetBy(dx: -w, dy: -w)
        checkpoint(name)
        let ink = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
        for path in paths {
            // An ink annotation's paths are measured from the corner of its own box.
            let local = path.copy() as! NSBezierPath
            local.transform(using: AffineTransform(translationByX: -box.minX, byY: -box.minY))
            ink.add(local)
        }
        ink.color = color ?? inkColor
        let border = PDFBorder()
        border.lineWidth = w
        ink.border = border
        page.addAnnotation(ink)
        return ink
    }

    func placeSignature(on page: PDFPage, at point: NSPoint) {
        guard let strokes = SignatureStore.load(), !strokes.isEmpty else {
            drawSignature(nil)
            return
        }
        let all = strokes.flatMap { $0 }
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        let scale = 170 / max(maxX - minX, 1)
        let size = NSSize(width: (maxX - minX) * scale, height: (maxY - minY) * scale)
        let paths = strokes.map { stroke -> NSBezierPath in
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (i, p) in stroke.enumerated() {
                let q = NSPoint(x: point.x - size.width / 2 + (p.x - minX) * scale,
                                y: point.y - size.height / 2 + (p.y - minY) * scale)
                i == 0 ? path.move(to: q) : path.line(to: q)
            }
            if stroke.count == 1 { path.line(to: path.currentPoint) }
            return path
        }
        let ink = addInk(paths, on: page, color: NSColor(srgbRed: 0.08, green: 0.15, blue: 0.45, alpha: 1),
                         width: 1.6, name: "Sign")
        setTool(.select)
        if let ink { canvas.selectAnnotation((ink, page)) }
        status("Signed. Drag the signature to move it, or press Delete to remove it.")
    }

    @objc func drawSignature(_ sender: Any?) {
        guard let window else { return }
        SignaturePad.present(on: window) { [weak self] saved in
            if saved {
                self?.setTool(.signature)
                self?.status("Signature saved. Click where it should go.")
            }
        }
    }

    func placeImage(on page: PDFPage, at point: NSPoint) {
        guard let doc = pdf else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to place on the page."
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
              image.size.width > 0 else { return }
        // Everything goes to the helper as PNG, so HEIC and other Mac-only formats work too.
        let dir = Helper.scratch()
        let png = dir.appendingPathComponent("picture.png")
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]),
              (try? data.write(to: png)) != nil else {
            showError("Couldn't read that picture.", in: window)
            return
        }
        let pageBox = page.bounds(for: .cropBox)
        let width = min(200, pageBox.width * 0.6)
        let height = width * image.size.height / image.size.width
        let rect = NSRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        let index = doc.index(for: page)
        transform("Add Image", busy: "Placing the picture…", { i, o in
            ["insert-image", i, o, "\(index)"] + self.numbers(rect) + [png.path]
        }, done: { _ in
            try? FileManager.default.removeItem(at: dir)
            self.status("Picture placed. It's part of the page now. Undo (⌘Z) and click again to put it somewhere else.")
        })
    }

    // MARK: File

    @objc func saveDocument(_ sender: Any?) {
        guard let url = fileURL else { saveDocumentAs(sender); return }
        write(to: url)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window, pdf != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = displayName + ".pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.write(to: url)
        }
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        activeField?.finish()
        guard let data = pdf?.dataRepresentation() else { return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError("Couldn't save: \(error.localizedDescription)", in: window)
            return false
        }
        fileURL = url
        dirty = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        status("Saved \(url.lastPathComponent) (\(Self.megabytes(data.count))).")
        return true
    }

    @objc func exportWord(_ sender: Any?) {
        guard let window, !busy, let data = pdf?.dataRepresentation() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
        panel.nameFieldStringValue = displayName + ".docx"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url else { return }
            let dir = Helper.scratch()
            let input = dir.appendingPathComponent("in.pdf")
            try? data.write(to: input)
            self.setBusy("Converting to Word…")
            Helper.run(["to-docx", input.path, dest.path]) { result in
                try? FileManager.default.removeItem(at: dir)
                self.setBusy(nil)
                switch result {
                case .success:
                    self.status("Saved \(dest.lastPathComponent). Layouts with columns or tables may need tidying in Word.")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                case .failure(let failure):
                    self.status("")
                    showError(failure.message, in: self.window)
                }
            }
        }
    }

    @objc func exportImages(_ sender: Any?) {
        guard let window, let doc = pdf else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        let chosen = sidebar.selectedIndexes
        let pages = chosen.count > 1 ? chosen : Array(0..<doc.pageCount)
        panel.message = "Each page becomes one picture (\(pages.count) page\(pages.count == 1 ? "" : "s"))."
        let format = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        format.addItems(withTitles: ["PNG, 150 dpi", "PNG, 300 dpi", "JPEG, 150 dpi", "JPEG, 300 dpi"])
        panel.accessoryView = format
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            let jpeg = format.indexOfSelectedItem >= 2
            let dpi: CGFloat = format.indexOfSelectedItem % 2 == 0 ? 150 : 300
            var written = 0
            for index in pages {
                guard let page = doc.page(at: index), let rep = Convert.bitmap(of: page, dpi: dpi),
                      let data = rep.representation(using: jpeg ? .jpeg : .png,
                                                    properties: jpeg ? [.compressionFactor: 0.85] : [:]) else { continue }
                let name = String(format: "%@-p%03d.%@", self.displayName, index + 1, jpeg ? "jpg" : "png")
                if (try? data.write(to: folder.appendingPathComponent(name))) != nil { written += 1 }
            }
            self.status("Exported \(written) picture\(written == 1 ? "" : "s") to \(folder.lastPathComponent).")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    @objc func compress(_ sender: Any?) {
        transform("Compress", busy: "Compressing…", { i, o in ["compress", i, o] }, done: { json in
            let before = json["before"] as? Int ?? 0, after = json["after"] as? Int ?? 0
            if after < before {
                let saved = Int((1 - Double(after) / Double(max(before, 1))) * 100)
                self.status("Compressed \(Self.megabytes(before)) → \(Self.megabytes(after)) (\(saved)% smaller). Save to keep it.")
            } else {
                self.status("This PDF is already about as small as it gets (\(Self.megabytes(after))).")
            }
        })
    }

    @objc func printDocument(_ sender: Any?) {
        canvas.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    static func megabytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: OCR

    @objc func makeSearchable(_ sender: Any?) {
        guard !busy, let doc = pdf else { return }
        let targets = (0..<doc.pageCount).filter {
            (doc.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 3
        }
        guard !targets.isEmpty else {
            status("Every page already has text you can select and search.")
            return
        }
        setBusy("Reading \(targets.count) scanned page\(targets.count == 1 ? "" : "s")…")
        let jobs = targets.compactMap { index -> OCR.Job? in
            guard let page = doc.page(at: index), let image = Convert.bitmap(of: page, dpi: 200)?.cgImage else { return nil }
            return OCR.Job(page: index, image: image, box: page.bounds(for: .cropBox), rotation: page.rotation)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = OCR.recognise(jobs)
            DispatchQueue.main.async {
                self.setBusy(nil)
                let lines = found.reduce(0) { $0 + (($1["lines"] as? [Any])?.count ?? 0) }
                guard lines > 0 else {
                    self.status("No text was found on the scanned pages.")
                    return
                }
                let dir = Helper.scratch()
                let words = dir.appendingPathComponent("words.json")
                guard let data = try? JSONSerialization.data(withJSONObject: found),
                      (try? data.write(to: words)) != nil else { return }
                self.transform("Make Searchable", busy: "Adding the text layer…", { i, o in
                    ["ocr-layer", i, o, words.path]
                }, done: { _ in
                    try? FileManager.default.removeItem(at: dir)
                    self.status("Found \(lines) lines of text on \(found.count) page\(found.count == 1 ? "" : "s"). Search and copy work now.")
                })
            }
        }
    }

    // MARK: Pages

    /// The pages a page command acts on: those picked in the sidebar, or the one on screen.
    private var targetPages: [Int] {
        let picked = sidebar.selectedIndexes
        return picked.isEmpty ? [currentIndex] : picked
    }

    @objc func rotateLeft(_ sender: Any?) { rotate(by: -90) }
    @objc func rotateRight(_ sender: Any?) { rotate(by: 90) }

    private func rotate(by degrees: Int) {
        guard let doc = pdf else { return }
        let targets = targetPages
        checkpoint("Rotate")
        for index in targets {
            guard let page = doc.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        canvas.layoutDocumentView()
        sidebar.reload(keeping: targets)
    }

    @objc func deletePages(_ sender: Any?) {
        guard let doc = pdf else { return }
        let targets = targetPages
        guard targets.count < doc.pageCount else {
            showError("A PDF needs at least one page, so the last one can't be deleted.", in: window)
            return
        }
        checkpoint(targets.count == 1 ? "Delete Page" : "Delete Pages")
        for index in targets.sorted(by: >) { doc.removePage(at: index) }
        sidebar.reload()
        updateChrome()
        status("Deleted \(targets.count) page\(targets.count == 1 ? "" : "s").")
    }

    @objc func duplicatePages(_ sender: Any?) {
        guard let doc = pdf else { return }
        let targets = targetPages
        checkpoint("Duplicate")
        for index in targets.sorted(by: >) {
            guard let copy = doc.page(at: index)?.copy() as? PDFPage else { continue }
            doc.insert(copy, at: index + 1)
        }
        sidebar.reload()
        updateChrome()
    }

    @objc func insertBlankPage(_ sender: Any?) {
        guard let doc = pdf else { return }
        let size = canvas.currentPage?.bounds(for: .mediaBox) ?? NSRect(x: 0, y: 0, width: 595, height: 842)
        let blank = PDFPage()
        blank.setBounds(NSRect(origin: .zero, size: size.size), for: .mediaBox)
        checkpoint("Insert Blank Page")
        doc.insert(blank, at: currentIndex + 1)
        sidebar.reload()
        canvas.go(to: blank)
        updateChrome()
    }

    @objc func insertFromFile(_ sender: Any?) {
        guard let window, pdf != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Convert.importableTypes
        panel.allowsMultipleSelection = true
        panel.message = "Pick PDFs, images or Word files. Their pages go in after page \(currentIndex + 1)."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            self.insertFiles(panel.urls, at: self.currentIndex + 1)
        }
    }

    func insertFiles(_ urls: [URL], at position: Int) {
        guard let doc = pdf else { return }
        let pages = urls.flatMap(Convert.pages(from:))
        guard !pages.isEmpty else {
            showError("None of those files could be read.", in: window)
            return
        }
        checkpoint("Insert Pages")
        var at = min(position, doc.pageCount)
        for page in pages {
            doc.insert(page, at: at)
            at += 1
        }
        sidebar.reload()
        updateChrome()
        status("Inserted \(pages.count) page\(pages.count == 1 ? "" : "s").")
    }

    func movePages(_ rows: IndexSet, to row: Int) {
        guard let doc = pdf else { return }
        let pages = rows.compactMap { doc.page(at: $0) }
        let target = row - rows.filter { $0 < row }.count
        guard !(rows.count == 1 && (rows.first == row || rows.first == row - 1)) else { return }
        checkpoint("Move Pages")
        for index in rows.sorted(by: >) { doc.removePage(at: index) }
        for (offset, page) in pages.enumerated() { doc.insert(page, at: target + offset) }
        sidebar.reload(keeping: Array(target..<(target + pages.count)))
        canvas.go(to: pages[0])
        updateChrome()
    }

    @objc func extractPages(_ sender: Any?) {
        guard let window, let doc = pdf else { return }
        let targets = targetPages.sorted()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let label = targets.count == 1 ? "page \(targets[0] + 1)" : "pages \(targets.map { "\($0 + 1)" }.joined(separator: ","))"
        panel.nameFieldStringValue = "\(displayName) (\(label)).pdf"
        panel.message = "Saves \(label) as a new PDF. This document isn't changed."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let out = PDFDocument()
            for index in targets {
                if let copy = doc.page(at: index)?.copy() as? PDFPage { out.insert(copy, at: out.pageCount) }
            }
            if out.write(to: url) {
                self.status("Saved \(url.lastPathComponent).")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                showError("Couldn't save \(url.lastPathComponent).", in: self.window)
            }
        }
    }

    @objc func splitPages(_ sender: Any?) {
        guard let window, let doc = pdf else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Split Here"
        panel.message = "Every page is saved as its own PDF (\(doc.pageCount) files)."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            var written = 0
            for index in 0..<doc.pageCount {
                let out = PDFDocument()
                guard let copy = doc.page(at: index)?.copy() as? PDFPage else { continue }
                out.insert(copy, at: 0)
                let name = String(format: "%@-p%03d.pdf", self.displayName, index + 1)
                if out.write(to: folder.appendingPathComponent(name)) { written += 1 }
            }
            self.status("Split into \(written) files in \(folder.lastPathComponent).")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    @objc func deleteSelection(_ sender: Any?) {
        if canvas.selected != nil {
            canvas.deleteSelectedAnnotation()
        } else if window?.firstResponder === sidebar.table {
            deletePages(sender)
        }
    }

    // MARK: View and search

    @objc func zoomIn(_ sender: Any?) { canvas.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomOut(sender) }
    @objc func zoomFit(_ sender: Any?) { canvas.autoScales = true }
    @objc func nextPage(_ sender: Any?) { canvas.goToNextPage(sender) }
    @objc func previousPage(_ sender: Any?) { canvas.goToPreviousPage(sender) }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchItem.searchField)
    }

    @objc func search(_ sender: NSSearchField) {
        guard let doc = pdf else { return }
        let text = sender.stringValue
        guard !text.isEmpty else { canvas.clearSelection(); status(""); return }
        let total = doc.findString(text, withOptions: .caseInsensitive).count
        guard total > 0 else {
            status("“\(text)” isn't in this PDF. (Scans need Tools ▸ Make Searchable first.)")
            return
        }
        let next = doc.findString(text, fromSelection: canvas.currentSelection, withOptions: .caseInsensitive)
            ?? doc.findString(text, fromSelection: nil, withOptions: .caseInsensitive)
        guard let next else { return }
        canvas.setCurrentSelection(next, animate: true)
        canvas.go(to: next)
        status("\(total) match\(total == 1 ? "" : "es"). Press Return for the next.")
    }

    // MARK: Menus, drops, closing

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasDoc = pdf != nil
        switch item.action {
        case #selector(chooseTool(_:)):
            item.state = canvas.tool.rawValue == item.tag ? .on : .off
            return hasDoc
        case #selector(deleteSelection(_:)):
            return canvas.selected != nil || (window?.firstResponder === sidebar.table && hasDoc)
        case #selector(deletePages(_:)):
            return hasDoc && (pdf?.pageCount ?? 0) > 1
        case #selector(printDocument(_:)), #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)),
             #selector(exportWord(_:)), #selector(exportImages(_:)), #selector(compress(_:)),
             #selector(makeSearchable(_:)), #selector(removeAllHighlights(_:)), #selector(rotateLeft(_:)), #selector(rotateRight(_:)),
             #selector(duplicatePages(_:)), #selector(insertFromFile(_:)), #selector(insertBlankPage(_:)),
             #selector(extractPages(_:)), #selector(splitPages(_:)), #selector(zoomIn(_:)),
             #selector(zoomOut(_:)), #selector(zoomFit(_:)), #selector(nextPage(_:)),
             #selector(previousPage(_:)), #selector(focusSearch(_:)):
            return hasDoc && !busy
        default:
            return true
        }
    }

    private func handleDrop(_ urls: [URL]) {
        if pdf == nil {
            let delegate = NSApp.delegate as? AppDelegate
            if urls.count == 1, urls[0].pathExtension.lowercased() == "pdf" {
                delegate?.open(urls[0])
            } else {
                delegate?.openAsNew(urls)
            }
        } else {
            insertFiles(urls, at: currentIndex + 1)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        activeField?.finish()
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName)”?"
        alert.informativeText = "If you don't save, your changes are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: sender) { response in
            switch response {
            case .alertFirstButtonReturn:
                if self.fileURL != nil {
                    if self.write(to: self.fileURL!) { sender.close() }
                } else {
                    self.saveDocumentAs(nil)
                }
            case .alertThirdButtonReturn:
                self.dirty = false
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.editors.removeAll { $0 === self }
    }
}

/// The window's content view: takes files dropped anywhere on the window.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(sender)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped)
        return true
    }
}
