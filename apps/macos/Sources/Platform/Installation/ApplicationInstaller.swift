import Foundation
import Security

enum ApplicationInstallationError: Error, Equatable {
    case invalidApplication, occupiedDestination, changedDestination, applicationRunning
    case cannotRestore(URL)
}

/// Installs only the app bundle. Document and preference locations are untouched.
/// A previous bundle is retained until the installed application opens successfully.
actor ApplicationInstaller {
    private let source: URL
    let destination: URL
    private let validate: @Sendable (URL) throws -> Void
    private var workspace: URL?
    private var originalIdentity: UInt64?
    private var installedIdentity: UInt64?
    private var backedUp = false

    init(source: URL, destination: URL, validate: @escaping @Sendable (URL) throws -> Void = ApplicationInstaller.verifySignature) {
        self.source = source.resolvingSymlinksInPath(); self.destination = destination
        self.validate = validate
    }
    private func identity(_ url: URL) throws -> UInt64? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ApplicationInstallationError.occupiedDestination }
        guard let value = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { throw ApplicationInstallationError.occupiedDestination }
        return value
    }
    private func isLino(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == "dev.open-typora.editor" && info["CFBundleExecutable"] as? String == "Lino"
    }
    func install(beforeReplacing: @MainActor @Sendable () throws -> Void = {}) async throws -> URL {
        let fm = FileManager.default
        guard workspace == nil, isLino(source), source != destination.resolvingSymlinksInPath() else { throw ApplicationInstallationError.invalidApplication }
        try validate(source)
        originalIdentity = try identity(destination)
        if originalIdentity != nil, !isLino(destination) { throw ApplicationInstallationError.occupiedDestination }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let work = destination.deletingLastPathComponent().appendingPathComponent(".lino-install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false); workspace = work
        do {
            let copy = work.appendingPathComponent("Lino.app")
            try fm.copyItem(at: source, to: copy)
            try validate(copy); try Task.checkCancellation()
            try await beforeReplacing()
            try Task.checkCancellation()
            guard try identity(destination) == originalIdentity else { throw ApplicationInstallationError.changedDestination }
            if originalIdentity != nil { try fm.moveItem(at: destination, to: work.appendingPathComponent("Previous.app")); backedUp = true }
            do { try fm.moveItem(at: copy, to: destination); installedIdentity = try identity(destination) }
            catch { try rollback(); throw error }
            try Task.checkCancellation()
            return destination
        } catch { try rollback(); throw error }
    }
    func complete() throws {
        if let workspace { try FileManager.default.removeItem(at: workspace) }
        workspace = nil; installedIdentity = nil; backedUp = false
    }
    func rollback() throws {
        guard let workspace else { return }
        let fm = FileManager.default
        do {
            if let installedIdentity {
                guard try identity(destination) == installedIdentity else { throw ApplicationInstallationError.cannotRestore(workspace) }
                try fm.removeItem(at: destination); self.installedIdentity = nil
            }
            if backedUp {
                guard !fm.fileExists(atPath: destination.path) else { throw ApplicationInstallationError.cannotRestore(workspace) }
                try fm.moveItem(at: workspace.appendingPathComponent("Previous.app"), to: destination); backedUp = false
            }
            try fm.removeItem(at: workspace); self.workspace = nil
        } catch { throw ApplicationInstallationError.cannotRestore(workspace) }
    }
    nonisolated static func verifySignature(_ url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw ApplicationInstallationError.invalidApplication }
    }
}
