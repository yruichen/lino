import AppKit

@MainActor
final class LatexCompileCoordinator {
    private let bridge: EditorBridge
    private weak var window: NSWindow?
    private var job: CompileJob?
    private var preview: LatexPreviewWindowController?
    private var generation = 0
    private(set) var busy = false
    private(set) var cancellable = false
    var onError: ((String) -> Void)?
    var onNotice: ((String) -> Void)?

    init(bridge: EditorBridge, window: NSWindow) {
        self.bridge = bridge
        self.window = window
    }

    func compile(sessionId: String, epoch: String, label: String?) async {
        guard !busy, let window else { return }
        busy = true
        cancellable = true
        generation += 1
        let operation = generation
        let view = bridge.generation
        defer {
            job = nil
            busy = false
            cancellable = false
        }
        do {
            let profile = String(decoding: try JSONSerialization.data(withJSONObject: "latexmk_xelatex"), as: UTF8.self)
            let current = try await bridge.backend.perform { try $0.beginCompile(sessionId: sessionId, epoch: epoch, profileJson: profile) }
            job = current
            onNotice?("latex.compiling")
            try await bridge.backend.perform { _ in try current.run() }
            guard operation == generation, view == bridge.generation else { return }
            let status = try await decodeStatus(try await bridge.backend.perform { _ in try current.status() })
            guard status["state"] as? String == "succeeded", status["stale"] as? Bool != true else {
                if status["state"] as? String == "failed" {
                    throw NSError(domain: "Lino.Latex", code: 2, userInfo: [NSLocalizedDescriptionKey: (status["log"] as? String) ?? localized("latex.failed")])
                }
                return
            }
            let bytes = try await bridge.backend.perform { _ in try current.pdf() }
            guard operation == generation, view == bridge.generation else { return }
            let data = Data(bytes)
            let next = try LatexPreviewWindowController(data: data, label: label ?? localized("document.untitled"))
            preview?.close()
            preview = next
            next.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            onNotice?("latex.compiled")
        } catch is CancellationError {
            onNotice?("latex.cancelled")
        } catch {
            if operation == generation && view == bridge.generation {
                onError?(userFacingError(error))
            }
        }
    }

    func cancel() {
        guard busy, cancellable else { return }
        generation += 1
        _ = job?.cancel()
        onNotice?("latex.cancelled")
    }

    func detach() {
        generation += 1
        _ = job?.cancel()
        job = nil
        preview?.close()
        preview = nil
    }

    private func decodeStatus(_ json: String) async throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "Lino.Latex", code: 3, userInfo: [NSLocalizedDescriptionKey: localized("latex.failed")])
        }
        return value
    }
}
