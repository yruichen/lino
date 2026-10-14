import AppKit
import UniformTypeIdentifiers

@MainActor
final class ExportCoordinator {
    enum Format { case html, pdf, printDocument }
    private let bridge: EditorBridge
    private weak var window: NSWindow?
    private var job: ExportJob?
    private var surface: PrintSurface?
    private var generation = 0
    private(set) var busy = false
    private(set) var cancellable = false
    private let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
    var onError: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    init(bridge: EditorBridge, window: NSWindow) { self.bridge = bridge; self.window = window }
    func pageSetup() {
        guard !busy, let window else { return }
        NSPageLayout().beginSheet(using: printInfo, on: window, completionHandler: nil)
    }
    private func requireCurrent(_ operation: Int, _ view: Int) throws {
        guard operation == generation, view == bridge.generation else { throw CancellationError() }
    }
    func export(_ format: Format, label: String?) async {
        guard !busy, let window else { return }
        busy = true; cancellable = true; generation += 1
        let operation = generation, view = bridge.generation
        var target: String?
        var temporary: URL?
        var scopedTarget: URL?
        defer {
            scopedTarget?.stopAccessingSecurityScopedResource()
            if let target { Task { try? await bridge.backend.perform { try $0.releaseSaveTarget(targetJson: target) } } }
            _ = job?.cancel(); job = nil; surface?.cancel(); surface = nil; busy = false; cancellable = false
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
        }
        do {
            let identity = try await bridge.call("exportIdentity") as? [String: String]
            guard let id = identity?["session_id"], let epoch = identity?["epoch"], let revision = identity?["revision"] else { throw NSError(domain: "Lino", code: 1) }
            try requireCurrent(operation, view)
            let job = try await bridge.backend.perform { try $0.beginExport(sessionId: id, epoch: epoch, revision: revision) }
            self.job = job; try requireCurrent(operation, view)
            _ = try await bridge.call("endExportCapture")
            if format != .printDocument {
                let panel = NSSavePanel(); panel.allowedContentTypes = [format == .html ? .html : .pdf]
                panel.nameFieldStringValue = ((label ?? localized("document.untitled")) as NSString).deletingPathExtension + (format == .html ? ".html" : ".pdf")
                guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { _ = job.cancel(); onNotice?("export.cancelled"); return }
                if url.startAccessingSecurityScopedResource() { scopedTarget = url }
                try requireCurrent(operation, view)
                target = try await bridge.backend.perform { try $0.saveTarget(path: url.path) }
            }
            onNotice?("export.rendering")
            let source = try await bridge.backend.perform { _ in try job.source() }
            let plan = try await bridge.call("prepareExport", arguments: [source]) as? [String: Any]
            guard let jobId = plan?["job_id"] as? String, let images = plan?["images"] as? [String] else { throw NSError(domain: "Lino", code: 1) }
            var resources: [String: String] = [:], bytes = 0
            for image in images {
                try requireCurrent(operation, view)
                let content: ImageContent
                do { content = try await bridge.backend.perform { _ in try job.readImage(source: image) } }
                catch {
                    if let failure = error as? BackendFailure, ["denied", "not_found", "unsupported_operation"].contains(failure.code) {
                        throw NSError(domain: "Lino.Export", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("export.imageUnavailable", image)])
                    }
                    throw error
                }
                bytes += content.bytes.count
                guard bytes <= 16 * 1024 * 1024 else { throw NSError(domain: "Lino", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("export.imageLimit")]) }
                let data = Data(content.bytes); try ImageData.validate(data, mime: content.mime)
                resources[image] = "data:\(content.mime);base64,\(data.base64EncodedString())"
            }
            try requireCurrent(operation, view)
            let resourceJSON = String(decoding: try JSONSerialization.data(withJSONObject: resources), as: UTF8.self)
            guard let license = Bundle.main.resourceURL?.appendingPathComponent("Licenses/KaTeX.txt") else { throw NSError(domain: "Lino", code: 1) }
            let fontNotice = "\n/* KaTeX styles and fonts:\n" + (try String(contentsOf: license, encoding: .utf8)).replacingOccurrences(of: "*/", with: "* /") + "\n*/"
            guard let editor = Bundle.main.resourceURL?.appendingPathComponent("Editor"),
                  let html = try await bridge.call("renderExport", arguments: [jobId, resourceJSON, try String(contentsOf: editor.appendingPathComponent("math.css"), encoding: .utf8) + fontNotice]) as? String else { throw NSError(domain: "Lino", code: 1) }
            try requireCurrent(operation, view)
            let output: Data
            if format == .html { output = Data(html.utf8) }
            else {
                let surface = PrintSurface(); self.surface = surface; try await surface.load(html)
                try requireCurrent(operation, view)
                if format == .pdf {
                    temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lino-export-\(UUID().uuidString).pdf")
                } else {
                    try await bridge.backend.perform { _ in try job.beginPrint() }
                }
                cancellable = false
                let completed = await surface.print(in: window, info: printInfo, pdf: temporary)
                if format == .printDocument {
                    try await bridge.backend.perform { _ in try job.finishPrint(success: completed) }
                    if operation == generation && view == bridge.generation { onNotice?(completed ? "export.printSubmitted" : "export.printIncomplete") }; return
                }
                guard completed, let temporary else { _ = job.cancel(); onNotice?("export.printIncomplete"); return }
                output = try Data(contentsOf: temporary, options: .mappedIfSafe)
                guard output.starts(with: Data("%PDF-".utf8)) else { throw NSError(domain: "Lino", code: 1) }
            }
            try requireCurrent(operation, view)
            guard let target else { throw NSError(domain: "Lino", code: 1) }
            cancellable = false
            let data = output
            let durable = try await bridge.backend.perform { _ in try job.commit(targetJson: target, bytes: data) }
            if operation == generation && view == bridge.generation { onNotice?(durable ? "export.saved" : "export.savedNotDurable") }
        } catch is CancellationError { onNotice?("export.cancelled") }
        catch {
            if operation == generation && view == bridge.generation {
                onError?((error as? BackendFailure)?.code == "not_saved" ? localized("export.saveSource") : userFacingError(error))
            }
        }
        _ = try? await bridge.call("endExportCapture")
        _ = try? await bridge.call("cancelExport")
    }
    func cancel() {
        guard busy && cancellable else { return }
        if let job, !job.cancel() { return }
        generation += 1; surface?.cancel()
        Task { _ = try? await bridge.call("cancelExport") }
        onNotice?("export.cancelled")
    }
    func detach() { _ = job?.cancel(); generation += 1; surface?.cancel() }
}
