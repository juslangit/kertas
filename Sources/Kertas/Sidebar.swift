import AppKit
import PDFKit

/// Page thumbnails down the left. Click to jump, ⌘/⇧-click to pick several for
/// a page command, drag to reorder, drop files between pages to insert them.
final class Sidebar: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    weak var editor: EditorController?
    let table = NSTableView()
    private let cache = NSCache<PDFPage, NSImage>()
    private var syncing = false
    private static let rowType = NSPasteboard.PasteboardType("com.luqman.kertas.page-row")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 196
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.allowsMultipleSelection = true
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.menu = contextMenu()
        documentView = table
        hasVerticalScroller = true
        drawsBackground = false
    }
    required init?(coder: NSCoder) { fatalError() }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("Rotate Left", #selector(EditorController.rotateLeft(_:))),
            ("Rotate Right", #selector(EditorController.rotateRight(_:))),
            ("Duplicate", #selector(EditorController.duplicatePages(_:))),
            ("Extract…", #selector(EditorController.extractPages(_:))),
            ("Insert Pages from File…", #selector(EditorController.insertFromFile(_:))),
            ("Delete", #selector(EditorController.deletePages(_:))),
        ]
        for (title, action) in items {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        }
        return menu
    }

    /// Right-clicking a page that isn't picked picks it, so the menu acts on what you clicked.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        if row >= 0, !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    var selectedIndexes: [Int] {
        table.selectedRowIndexes.count > 1 || window?.firstResponder === table
            ? Array(table.selectedRowIndexes) : []
    }

    func reload(keeping rows: [Int]? = nil) {
        cache.removeAllObjects()
        let keep = rows.map(IndexSet.init) ?? table.selectedRowIndexes
        syncing = true
        table.reloadData()
        let count = table.numberOfRows
        table.selectRowIndexes(IndexSet(keep.filter { $0 < count }), byExtendingSelection: false)
        syncing = false
    }

    func showCurrent(_ index: Int) {
        guard index < table.numberOfRows, !table.selectedRowIndexes.contains(index) else { return }
        syncing = true
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)
        syncing = false
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { editor?.pdf?.pageCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PageCell.id, owner: nil) as? PageCell ?? PageCell()
        guard let page = editor?.pdf?.page(at: row) else { return cell }
        if let image = cache.object(forKey: page) {
            cell.thumb.image = image
        } else {
            let image = page.thumbnail(of: NSSize(width: 120, height: 160), for: .cropBox)
            cache.setObject(image, forKey: page)
            cell.thumb.image = image
        }
        cell.number.stringValue = "\(row + 1)"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first,
              let page = editor?.pdf?.page(at: row) else { return }
        editor?.canvas.go(to: page)
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === tableView ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let items = info.draggingPasteboard.pasteboardItems ?? []
        let rows = IndexSet(items.compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) })
        if !rows.isEmpty {
            editor?.movePages(rows, to: row)
            return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        editor?.insertFiles(urls, at: row)
        return true
    }
}

private final class PageCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("PageCell")
    let thumb = NSImageView()
    let number = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        thumb.imageScaling = .scaleProportionallyDown
        thumb.wantsLayer = true
        thumb.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 3
            s.shadowColor = .black.withAlphaComponent(0.3)
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        number.font = .systemFont(ofSize: 11)
        number.textColor = .secondaryLabelColor
        number.alignment = .center
        for view in [thumb, number] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            thumb.centerXAnchor.constraint(equalTo: centerXAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 120),
            thumb.heightAnchor.constraint(equalToConstant: 160),
            number.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 4),
            number.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
