import AppKit
import PDFKit

enum Tool: Int, CaseIterable {
    case select, editText, addText, highlight, draw, signature, image

    var title: String {
        switch self {
        case .select: "Select"
        case .editText: "Edit Text"
        case .addText: "Add Text"
        case .highlight: "Highlight"
        case .draw: "Draw"
        case .signature: "Sign"
        case .image: "Add Image"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .editText: "character.cursor.ibeam"
        case .addText: "textbox"
        case .highlight: "highlighter"
        case .draw: "pencil.tip"
        case .signature: "signature"
        case .image: "photo"
        }
    }

    var hint: String {
        switch self {
        case .select: "Click to select an annotation, drag to move it, Delete to remove it. Double-click text you added to change it."
        case .editText: "Click a line of text in the PDF to rewrite it. Return saves, Esc cancels."
        case .addText: "Click where the text should go, type, then press Return."
        case .highlight: "Drag across text to highlight it."
        case .draw: "Drag to draw. Colour and thickness come from the toolbar."
        case .signature: "Click where your signature should go."
        case .image: "Click where the picture should go."
        }
    }
}

/// The page view. PDFKit's PDFView does the showing, scrolling and form filling;
/// this subclass adds what happens when you click with each tool.
final class Canvas: PDFView {
    weak var editor: EditorController?
    var tool: Tool = .select { didSet { selectAnnotation(nil); window?.invalidateCursorRects(for: self) } }

    private(set) var selected: (annotation: PDFAnnotation, page: PDFPage)?
    private var drag: (start: NSPoint, original: NSRect, moved: Bool)?
    private var stroke: (path: NSBezierPath, page: PDFPage)?
    private let overlay = Overlay()

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        autoScales = true
        backgroundColor = .underPageBackgroundColor
        NotificationCenter.default.addObserver(self, selector: #selector(layoutChanged),
                                               name: .PDFViewScaleChanged, object: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var document: PDFDocument? {
        didSet { selected = nil; stroke = nil; attachOverlay() }
    }

    // MARK: Overlay — the selection box and the stroke being drawn

    /// The overlay sits inside PDFKit's own document view, so it scrolls and
    /// zooms with the pages without any bookkeeping.
    private func attachOverlay() {
        guard let host = documentView else { return }
        if overlay.superview !== host {
            overlay.removeFromSuperview()
            overlay.frame = host.bounds
            overlay.autoresizingMask = [.width, .height]
            host.addSubview(overlay)
        }
        layoutChanged()
    }

    @objc func layoutChanged() {
        guard let host = documentView else { return }
        overlay.frame = host.bounds
        overlay.box = selected.map { host.convert(convert($0.annotation.bounds, from: $0.page), from: self) }
        if let stroke {
            // Each point goes through the same conversion as the selection box.
            // Scaling by scaleFactor instead zoomed the stroke twice, because
            // the document view is already drawn at the zoom.
            let toHost = { (p: NSPoint) in host.convert(self.convert(p, from: stroke.page), from: self) }
            let path = NSBezierPath()
            var points = [NSPoint](repeating: .zero, count: 3)
            for i in 0..<stroke.path.elementCount {
                switch stroke.path.element(at: i, associatedPoints: &points) {
                case .moveTo: path.move(to: toHost(points[0]))
                case .lineTo: path.line(to: toHost(points[0]))
                default: break
                }
            }
            let unit = hypot(toHost(NSPoint(x: 1, y: 0)).x - toHost(.zero).x, toHost(NSPoint(x: 1, y: 0)).y - toHost(.zero).y)
            path.lineWidth = (editor?.lineWidth ?? 2) * unit
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            overlay.stroke = path
            overlay.strokeColor = editor?.inkColor ?? .black
        } else {
            overlay.stroke = nil
        }
        overlay.needsDisplay = true
    }

    func selectAnnotation(_ pick: (PDFAnnotation, PDFPage)?) {
        selected = pick.map { (annotation: $0.0, page: $0.1) }
        layoutChanged()
    }

    // MARK: Mouse

    private func pageAndPoint(_ event: NSEvent) -> (PDFPage, NSPoint)? {
        let inView = convert(event.locationInWindow, from: nil)
        guard let page = page(for: inView, nearest: false) else { return nil }
        return (page, convert(inView, to: page))
    }

    /// Annotations you can pick up and move. Form fields and links are left to PDFKit.
    private func movable(_ a: PDFAnnotation) -> Bool {
        !["Widget", "Link", "Popup"].contains(a.type ?? "")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let editor, let (page, point) = pageAndPoint(event) else {
            super.mouseDown(with: event)
            return
        }
        switch tool {
        case .select:
            if let hit = page.annotation(at: point), movable(hit) {
                selectAnnotation((hit, page))
                if event.clickCount == 2, hit.type == "FreeText" {
                    editor.beginAddText(on: page, at: point, editing: hit)
                    return
                }
                drag = (point, hit.bounds, false)
                return
            }
            selectAnnotation(nil)
            super.mouseDown(with: event)
        case .editText:
            editor.beginEditText(on: page, at: point)
        case .addText:
            editor.beginAddText(on: page, at: point, editing: nil)
        case .highlight:
            super.mouseDown(with: event)
        case .draw:
            let path = NSBezierPath()
            path.move(to: point)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            stroke = (path, page)
            layoutChanged()
        case .signature:
            editor.placeSignature(on: page, at: point)
        case .image:
            editor.placeImage(on: page, at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch tool {
        case .select where drag != nil:
            guard let (annotation, page) = selected, let start = drag?.start, let original = drag?.original else { return }
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            if drag?.moved == false {
                editor?.checkpoint("Move")
                drag?.moved = true
            }
            annotation.bounds = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            layoutChanged()
            setNeedsDisplay(bounds)
        case .draw:
            guard let stroke else { return }
            let point = convert(convert(event.locationInWindow, from: nil), to: stroke.page)
            stroke.path.line(to: point)
            layoutChanged()
        default:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .select where drag != nil:
            drag = nil
        case .draw:
            if let stroke { editor?.addInk([stroke.path], on: stroke.page) }
            stroke = nil
            layoutChanged()
        case .highlight:
            super.mouseUp(with: event)
            if let selection = currentSelection, !(selection.string ?? "").isEmpty {
                editor?.highlight(selection)
                clearSelection()
            }
        default:
            super.mouseUp(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]   // backspace, forward delete
        if selected != nil, deleteKeys.contains(event.keyCode) {
            deleteSelectedAnnotation()
            return
        }
        if event.keyCode == 53, tool != .select {  // Esc goes back to Select
            editor?.setTool(.select)
            return
        }
        super.keyDown(with: event)
    }

    func deleteSelectedAnnotation() {
        guard let (annotation, page) = selected else { return }
        editor?.checkpoint("Delete Annotation")
        page.removeAnnotation(annotation)
        selectAnnotation(nil)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch tool {
        case .select, .highlight: break
        case .editText, .addText: addCursorRect(bounds, cursor: .iBeam)
        case .draw, .signature, .image: addCursorRect(bounds, cursor: .crosshair)
        }
    }
}

/// Draws the selection box and the live pen stroke. Never takes a click.
private final class Overlay: NSView {
    var box: NSRect?
    var stroke: NSBezierPath?
    var strokeColor: NSColor = .black

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let box {
            let path = NSBezierPath(rect: box.insetBy(dx: -3, dy: -3))
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if let stroke {
            strokeColor.setStroke()
            stroke.stroke()
        }
    }
}
