import AppKit
import PDFKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Every open window. An editor removes itself when its window closes.
    var editors: [EditorController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        // Files opened from Finder arrive through application(_:open:) before this
        // runs; only show an empty window when nothing else was opened.
        DispatchQueue.main.async {
            if self.editors.isEmpty { self.newEditor().showWindow(nil) }
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newEditor().showWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = editors.filter(\.dirty)
        guard !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1
            ? "“\(unsaved[0].displayName)” has unsaved changes."
            : "\(unsaved.count) documents have unsaved changes."
        alert.informativeText = "If you quit now, the changes are lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: Opening

    @discardableResult
    func newEditor() -> EditorController {
        let editor = EditorController()
        editors.append(editor)
        return editor
    }

    /// Opens a file in the empty window if there is one, otherwise in a new window.
    func open(_ url: URL) {
        if let existing = editors.first(where: { $0.fileURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let kind = UTType(filenameExtension: url.pathExtension.lowercased())
        if kind?.conforms(to: .pdf) == true {
            guard let data = try? Data(contentsOf: url), PDFDocument(data: data) != nil else {
                showError("“\(url.lastPathComponent)” couldn't be opened as a PDF.")
                return
            }
            let editor = editors.first(where: { $0.pdf == nil }) ?? newEditor()
            editor.load(data: data, keepPlace: false)
            editor.fileURL = url
            editor.showWindow(nil)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            // For checking the Edit Text box without a mouse:
            //   open -a Kertas file.pdf --args -KertasCheckEditAt "x,y"   (PDF points, page 1)
            if let spot = UserDefaults.standard.string(forKey: "KertasCheckEditAt")?
                .split(separator: ",").compactMap({ Double($0) }), spot.count == 2,
               let page = editor.pdf?.page(at: 0) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    editor.setTool(.editText)
                    editor.beginEditText(on: page, at: NSPoint(x: spot[0], y: spot[1]))
                }
            }
        } else {
            openAsNew([url])
        }
    }

    /// Images and Word files become a new, untitled PDF.
    func openAsNew(_ urls: [URL]) {
        let doc = PDFDocument()
        var failed: [String] = []
        for url in urls {
            let pages = Convert.pages(from: url)
            if pages.isEmpty { failed.append(url.lastPathComponent) }
            for page in pages { doc.insert(page, at: doc.pageCount) }
        }
        if !failed.isEmpty { showError("Couldn't read: \(failed.joined(separator: ", "))") }
        guard doc.pageCount > 0, let data = doc.dataRepresentation() else { return }
        let editor = editors.first(where: { $0.pdf == nil }) ?? newEditor()
        editor.load(data: data, keepPlace: false)
        editor.fileURL = nil
        editor.dirty = true
        editor.showWindow(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }

    @objc func newFromFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Convert.importableTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose images or Word files. They become one PDF, in the order listed."
        guard panel.runModal() == .OK else { return }
        openAsNew(panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }

    @objc func combinePDFs(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the PDFs to combine. They are joined in name order; reorder pages afterwards in the sidebar."
        guard panel.runModal() == .OK else { return }
        openAsNew(panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }

    @objc func newWindow(_ sender: Any?) { newEditor().showWindow(nil) }

    // The system's recent-documents menu only works for NSDocument apps, so this
    // one is built by hand from the same list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.target = self
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError("“\(url.lastPathComponent)” has been moved or deleted.")
            return
        }
        open(url)
    }

    @objc func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func menu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            holder.submenu = sub
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        let sep = { NSMenuItem.separator() }

        menu("Kertas", [
            item("About Kertas", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            sep(),
            item("Hide Kertas", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("Quit Kertas", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self   // filled in each time it opens: menuNeedsUpdate
        recent.submenu = recentMenu

        menu("File", [
            item("New Window", #selector(newWindow(_:)), "n"),
            item("New PDF from Images or Word…", #selector(newFromFiles(_:)), "n", [.command, .shift]),
            item("Combine PDFs…", #selector(combinePDFs(_:))),
            sep(),
            item("Open…", #selector(openDocument(_:)), "o"),
            recent,
            sep(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(EditorController.saveDocument(_:)), "s"),
            item("Save As…", #selector(EditorController.saveDocumentAs(_:)), "s", [.command, .shift]),
            sep(),
            item("Export as Word…", #selector(EditorController.exportWord(_:))),
            item("Export as Images…", #selector(EditorController.exportImages(_:))),
            item("Compress…", #selector(EditorController.compress(_:))),
            sep(),
            item("Print…", #selector(EditorController.printDocument(_:)), "p"),
        ])

        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(EditorController.deleteSelection(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            sep(),
            item("Find…", #selector(EditorController.focusSearch(_:)), "f"),
        ])

        menu("Tools", Tool.allCases.map { tool in
            item(tool.title, #selector(EditorController.chooseTool(_:)), "\(tool.rawValue + 1)", tag: tool.rawValue)
        } + [
            sep(),
            item("Draw New Signature…", #selector(EditorController.drawSignature(_:))),
            item("Remove All Highlights", #selector(EditorController.removeAllHighlights(_:)), "h", [.command, .shift]),
            sep(),
            item("Make Searchable (OCR)", #selector(EditorController.makeSearchable(_:))),
        ])

        menu("Pages", [
            item("Rotate Left", #selector(EditorController.rotateLeft(_:)), "l"),
            item("Rotate Right", #selector(EditorController.rotateRight(_:)), "r"),
            sep(),
            item("Duplicate Page", #selector(EditorController.duplicatePages(_:)), "d"),
            item("Delete Page", #selector(EditorController.deletePages(_:)), "\u{8}"),
            sep(),
            item("Insert Pages from File…", #selector(EditorController.insertFromFile(_:)), "i", [.command, .option]),
            item("Insert Blank Page", #selector(EditorController.insertBlankPage(_:))),
            sep(),
            item("Extract Selected Pages…", #selector(EditorController.extractPages(_:)), "e", [.command, .option]),
            item("Split into Single Pages…", #selector(EditorController.splitPages(_:))),
        ])

        menu("View", [
            item("Zoom In", #selector(EditorController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(EditorController.zoomOut(_:)), "-"),
            item("Fit Width", #selector(EditorController.zoomFit(_:)), "0"),
            sep(),
            item("Next Page", #selector(EditorController.nextPage(_:)), "\u{F703}", [.command]),
            item("Previous Page", #selector(EditorController.previousPage(_:)), "\u{F702}", [.command]),
        ])

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        let windowHolder = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowHolder.submenu = windowMenu
        main.addItem(windowHolder)
        NSApp.windowsMenu = windowMenu

        return main
    }
}

func showError(_ message: String, in window: NSWindow? = nil) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}
