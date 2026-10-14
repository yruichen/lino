import AppKit
import UniformTypeIdentifiers

@MainActor
final class AssetActions {
    private let bridge: EditorBridge
    private let documents: DocumentActions
    private weak var window: NSWindow?
    private var running = false
    var onOpenDocument: ((String, String?) -> Void)?
    init(bridge: EditorBridge, documents: DocumentActions, window: NSWindow) { self.bridge = bridge; self.documents = documents; self.window = window }
    func request(id: String, operation: String, payload: String, fileRef: String?, sessionId: String?) {
        let generation = bridge.generation
        guard !running, documents.ready, (!documents.busy || operation == "copy-save-images"), !documents.closed,
              let session = documents.sessionId, let window else {
            respond(id, value: nil, error: localized("error.busy"), generation: generation); return
        }
        guard sessionId == session else { respond(id, value: nil, error: localized("media.oldResource"), generation: generation); return }
        running = true
        Task { [weak self] in
            guard let self else { return }
            defer { running = false }
            do {
                let value: String?
                switch operation {
                case "copy-save-images":
                    try requireCurrent(session, generation)
                    try await bridge.backend.perform { try $0.copySaveImages(sessionId: session, fileRef: fileRef, requestJson: payload) }
                    value = "copied"
                case "open-link":
                    try requireCurrent(session, generation)
                    if let url = URL(string: payload), let scheme = url.scheme?.lowercased() {
                        guard ["http", "https", "mailto"].contains(scheme), !payload.contains("\0") else { throw resourceError(localized("media.invalidResource")) }
                        guard NSWorkspace.shared.open(url) else { throw resourceError(localized("link.openFailed")) }
                        value = "requested"
                    } else {
                        let parts = payload.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                        let path = try await bridge.backend.perform { try $0.documentLinkPath(sessionId: session, fileRef: fileRef, source: String(parts[0])) }
                        try requireCurrent(session, generation)
                        guard let onOpenDocument else { throw resourceError(localized("link.openFailed")) }
                        onOpenDocument(path, parts.count > 1 ? String(parts[1]) : nil); value = "requested"
                    }
                case "import-image-path":
                    if ThemePalette.preferences?.image_insertion == "copy", !documents.hasFile { throw resourceError(localized("media.saveFirst")) }
                    try requireCurrent(session, generation)
                    value = try await bridge.backend.perform { try $0.importImageFile(sessionId: session, fileRef: fileRef, path: payload) }
                case "import-file":
                    if ThemePalette.preferences?.image_insertion == "copy", !documents.hasFile { throw resourceError(localized("media.saveFirst")) }
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    let selected = await panel.beginSheetModal(for: window)
                    if selected == .OK, let path = panel.url?.path {
                        try requireCurrent(session, generation)
                        value = try await bridge.backend.perform { try $0.importImageFile(sessionId: session, fileRef: fileRef, path: path) }
                    } else { value = nil }
                case "paste-image":
                    if ThemePalette.preferences?.image_insertion == "copy", !documents.hasFile { throw resourceError(localized("media.saveFirst")) }
                    guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) else { throw resourceError(localized("media.noClipboardImage")) }
                    let bytes: Data
                    do { bytes = try await Task.detached { try ImageData.png(data) }.value }
                    catch { throw resourceError(localized("media.imageLimit")) }
                    try requireCurrent(session, generation)
                    if ThemePalette.preferences?.image_insertion == "copy" {
                        value = try await bridge.backend.perform { try $0.importImageBytes(sessionId: session, fileRef: fileRef, name: "image.png", bytes: bytes) }
                    } else {
                        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Image.png"; panel.title = localized("media.saveClipboardImage")
                        if await panel.beginSheetModal(for: window) == .OK, let url = panel.url {
                            try requireCurrent(session, generation)
                            try await Task.detached { try bytes.write(to: url, options: .atomic) }.value
                            value = try await bridge.backend.perform { try $0.importImageFile(sessionId: session, fileRef: fileRef, path: url.path) }
                        } else { value = nil }
                    }
                case "reveal-image":
                    let path = try await bridge.backend.perform { try $0.imagePath(sessionId: session, fileRef: fileRef, source: payload) }
                    try requireCurrent(session, generation)
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]); value = "revealed"
                case "copy-image":
                    let content = try await bridge.backend.perform { try $0.readImage(sessionId: session, fileRef: fileRef, source: payload) }
                    try requireCurrent(session, generation)
                    do { try await Task.detached { try ImageData.validate(content.bytes, mime: content.mime) }.value }
                    catch { throw resourceError(localized("media.imageLimit")) }
                    try requireCurrent(session, generation)
                    guard let image = NSImage(data: content.bytes) else { throw resourceError(localized("media.imageLimit")) }
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.writeObjects([image]) else { throw resourceError(localized("error.clipboard")) }
                    value = "copied"
                case "save-svg":
                    guard payload.utf8.count <= 4 * 1024 * 1024, payload.contains("<svg") else { throw resourceError(localized("media.invalidResource")) }
                    let panel = NSSavePanel(); panel.allowedContentTypes = [.svg]; panel.nameFieldStringValue = "diagram.svg"
                    if await panel.beginSheetModal(for: window) == .OK, let url = panel.url {
                        try requireCurrent(session, generation)
                        try await Task.detached { try Data(payload.utf8).write(to: url, options: .atomic) }.value
                        value = url.lastPathComponent
                    } else { value = nil }
                default: throw resourceError(localized("media.invalidResource"))
                }
                try requireCurrent(session, generation)
                respond(id, value: value, error: nil, generation: generation)
            } catch { respond(id, value: nil, error: userFacingError(error), generation: generation) }
        }
    }
    private func requireCurrent(_ session: String, _ generation: Int) throws {
        guard documents.sessionId == session, !documents.closed, bridge.generation == generation else { throw resourceError(localized("media.oldResource")) }
    }
    private func respond(_ id: String, value: String?, error: String?, generation: Int) {
        Task { [weak self] in
            guard let self, bridge.generation == generation else { return }
            _ = try? await bridge.call("receiveAsset", arguments: [id, value as Any? ?? NSNull(), error as Any? ?? NSNull()])
        }
    }
}
