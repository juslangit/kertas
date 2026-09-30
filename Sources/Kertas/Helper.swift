import Foundation

/// Runs tools/helper.py — the Python side that does what PDFKit cannot:
/// change printed text, compress, write Word, and add an OCR text layer.
enum Helper {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kertas")

    /// The private Python made by setup.sh, with PyMuPDF and pdf2docx in it.
    static var python: String { supportDir.appendingPathComponent("venv/bin/python").path }

    /// build.sh points the app at the editable copy in the project, so changing
    /// the script needs no rebuild. The bundled copy is the fallback.
    static var script: String {
        if let path = ProcessInfo.processInfo.environment["KERTAS_HELPER"] { return path }   // the checks
        if let path = Bundle.main.object(forInfoDictionaryKey: "KertasHelper") as? String,
           FileManager.default.fileExists(atPath: path) { return path }
        return Bundle.main.path(forResource: "helper", ofType: "py") ?? ""
    }

    /// Runs one helper command off the main thread and reports back on it.
    static func run(_ args: [String], completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: python) else {
            completion(.failure(Failure(message: "Kertas's Python isn't set up yet. Run ./setup.sh in the project folder once.")))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runNow(args)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runNow(_ args: [String]) -> Result<[String: Any], Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return .failure(Failure(message: "Couldn't start the helper: \(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let lastLine = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: Any]
        if let message = json?["error"] as? String { return .failure(Failure(message: message)) }
        if let json, process.terminationStatus == 0 { return .success(json) }
        let detail = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init)
        return .failure(Failure(message: detail ?? "The helper stopped without saying why."))
    }

    /// A fresh scratch folder for one operation's input and output files.
    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kertas-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
