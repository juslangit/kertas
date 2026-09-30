// Headless checks for the app's Swift side: conversion, page pictures and OCR.
// Built by tests/run.sh together with Sources/Kertas/{Convert,Helper}.swift.
// Every check opens the file that was produced and measures it.
import AppKit
import PDFKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "  ok   " : "  FAIL ") + name + (ok ? "" : "  — \(detail())"))
    if !ok { failures += 1 }
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("kertas-app-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

// A one-page text PDF to work from.
let source = NSAttributedString(string: "Kertas check\nThe quick brown fox jumps over the lazy dog.\nInvoice 1042 total RM 250.00",
                                attributes: [.font: NSFont(name: "Helvetica", size: 22)!])
let textPDF = Convert.pdfData(from: source).flatMap(PDFDocument.init(data:))

print("text to PDF")
check("lays out an A4 page", textPDF?.page(at: 0)?.bounds(for: .mediaBox).size == Convert.a4.size,
      "\(String(describing: textPDF?.page(at: 0)?.bounds(for: .mediaBox)))")
check("text is real, selectable text", textPDF?.string?.contains("lazy dog") == true, textPDF?.string ?? "nil")

print("long text")
let long = NSAttributedString(string: String(repeating: "A line of a long report.\n", count: 200),
                              attributes: [.font: NSFont.systemFont(ofSize: 12)])
let longPDF = Convert.pdfData(from: long).flatMap(PDFDocument.init(data:))
check("runs onto several pages", (longPDF?.pageCount ?? 0) > 3, "\(longPDF?.pageCount ?? 0) pages")

print("page to picture")
let page = textPDF!.page(at: 0)!
let rep = Convert.bitmap(of: page, dpi: 150)
check("150 dpi gives the right pixel size", rep?.pixelsWide == 1240 && rep?.pixelsHigh == 1754,
      "\(rep?.pixelsWide ?? 0)×\(rep?.pixelsHigh ?? 0)")
page.rotation = 90
let turned = Convert.bitmap(of: page, dpi: 72)
check("a turned page comes out landscape", (turned?.pixelsWide ?? 0) > (turned?.pixelsHigh ?? 0),
      "\(turned?.pixelsWide ?? 0)×\(turned?.pixelsHigh ?? 0)")
page.rotation = 0

print("picture to PDF")
let png = work.appendingPathComponent("page.png")
try! rep!.representation(using: .png, properties: [:])!.write(to: png)
let scanned = Convert.pages(from: png)
check("one picture makes one A4 page", scanned.count == 1 && scanned[0].bounds(for: .mediaBox).size == Convert.a4.size)
check("the scan has no text yet", (scanned.first?.string ?? "").isEmpty)

print("OCR")
let scanDoc = PDFDocument()
scanDoc.insert(scanned[0], at: 0)
let scanPage = scanDoc.page(at: 0)!
let job = OCR.Job(page: 0, image: Convert.bitmap(of: scanPage, dpi: 200)!.cgImage!,
                  box: scanPage.bounds(for: .cropBox), rotation: 0)
let found = OCR.recognise([job])
let lines = (found.first?["lines"] as? [[String: Any]]) ?? []
let words = lines.compactMap { $0["text"] as? String }.joined(separator: " ")
check("Vision reads the scan", words.contains("lazy dog"), words)

// Hand the lines to the helper exactly as the app does, then search the result.
let input = work.appendingPathComponent("in.pdf"), output = work.appendingPathComponent("out.pdf")
let wordsFile = work.appendingPathComponent("words.json")
try! scanDoc.dataRepresentation()!.write(to: input)
try! JSONSerialization.data(withJSONObject: found).write(to: wordsFile)
let done = DispatchSemaphore(value: 0)
var helperResult: Result<[String: Any], Helper.Failure>?
DispatchQueue.global().async {
    Helper.run(["ocr-layer", input.path, output.path, wordsFile.path]) { helperResult = $0; done.signal() }
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
let searchable = PDFDocument(url: output)
let hit = searchable?.findString("lazy dog", withOptions: .caseInsensitive).first
check("the scan is searchable afterwards", hit != nil, "\(String(describing: helperResult))")
if let hit, let original = lines.first(where: { ($0["text"] as? String)?.contains("lazy dog") == true }),
   let r = (original["rect"] as? [CGFloat])?.map(Double.init) {
    let b = hit.bounds(for: searchable!.page(at: 0)!)
    check("found text sits on the printed words", abs(b.midY - (r[1] + r[3]) / 2) < 10,
          "hit \(b), line \(r)")
}

try? FileManager.default.removeItem(at: work)
print("\n\(failures == 0 ? "all passed" : "\(failures) failed")")
exit(failures == 0 ? 0 : 1)
