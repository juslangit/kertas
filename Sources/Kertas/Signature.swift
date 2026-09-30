import AppKit

/// Your signature, drawn once and kept as pen strokes (not a picture), so it
/// stays sharp at any size and goes into PDFs as an ink annotation.
enum SignatureStore {
    static var url: URL { Helper.supportDir.appendingPathComponent("signature.json") }

    static func load() -> [[CGPoint]]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([[CGPoint]].self, from: data)
    }

    static func save(_ strokes: [[CGPoint]]) {
        try? FileManager.default.createDirectory(at: Helper.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(strokes) { try? data.write(to: url) }
    }
}

/// The sheet where you sign with the trackpad or mouse.
final class SignaturePad: NSObject {
    private static var current: SignaturePad?
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                                styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
    private let pad = PadView()
    private var done: ((Bool) -> Void)?
    private weak var parent: NSWindow?

    static func present(on window: NSWindow, done: @escaping (Bool) -> Void) {
        let sheet = SignaturePad()
        sheet.done = done
        sheet.parent = window
        current = sheet
        window.beginSheet(sheet.panel)
    }

    private override init() {
        super.init()
        let title = NSTextField(labelWithString: "Sign in the box: click and drag with the trackpad or mouse.")
        title.font = .systemFont(ofSize: 13)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearPad))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save Signature", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [clear, NSView(), cancel, save])
        let stack = NSStackView(views: [title, pad, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.heightAnchor.constraint(equalToConstant: 180).isActive = true
        pad.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        buttons.widthAnchor.constraint(equalTo: pad.widthAnchor).isActive = true
        panel.contentView = stack
    }

    @objc private func clearPad() { pad.strokes = []; pad.needsDisplay = true }
    @objc private func cancel() { close(saved: false) }

    @objc private func save() {
        let strokes = pad.strokes.filter { !$0.isEmpty }
        guard !strokes.isEmpty else { NSSound.beep(); return }
        SignatureStore.save(strokes)
        close(saved: true)
    }

    private func close(saved: Bool) {
        parent?.endSheet(panel)
        done?(saved)
        Self.current = nil
    }
}

private final class PadView: NSView {
    var strokes: [[CGPoint]] = []

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        // A baseline to sign on, like paper.
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 24, y: 48))
        line.line(to: NSPoint(x: bounds.width - 24, y: 48))
        NSColor.tertiaryLabelColor.setStroke()
        line.stroke()

        NSColor(srgbRed: 0.08, green: 0.15, blue: 0.45, alpha: 1).setStroke()
        for stroke in strokes where !stroke.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            for p in stroke.dropFirst() { path.line(to: p) }
            if stroke.count == 1 { path.line(to: stroke[0]) }
            path.stroke()
        }
    }
}
