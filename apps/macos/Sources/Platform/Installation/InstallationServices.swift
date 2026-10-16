import AppKit
import UniformTypeIdentifiers

/// Launch Services owns file associations; these are machine settings, not document preferences.
@MainActor
final class InstallationServices {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    let applicationURL: URL
    init(applicationURL: URL = Bundle.main.bundleURL) { self.applicationURL = applicationURL }
    var installed: Bool { Self.isInstalled(applicationURL, home: FileManager.default.homeDirectoryForCurrentUser) }
    var destination: URL {
        let folder = FileManager.default.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications", isDirectory: true) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        return folder.appendingPathComponent("Lino.app", isDirectory: true)
    }
    var existingApplication: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }
    }
    func installAndOpen(paths: [URL]) async throws {
        guard existingApplication == nil else { throw ApplicationInstallationError.applicationRunning }
        let installer = ApplicationInstaller(source: applicationURL, destination: destination)
        do {
            let target = try await installer.install { [weak self] in
                guard self?.existingApplication == nil else { throw ApplicationInstallationError.applicationRunning }
            }
            guard existingApplication == nil else { throw ApplicationInstallationError.applicationRunning }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
                    if let error { continuation.resume(throwing: error) }
                    else if app == nil { continuation.resume(throwing: ApplicationInstallationError.invalidApplication) }
                    else { continuation.resume() }
                }
                if paths.isEmpty { NSWorkspace.shared.openApplication(at: target, configuration: configuration, completionHandler: completion) }
                else { NSWorkspace.shared.open(paths, withApplicationAt: target, configuration: configuration, completionHandler: completion) }
            }
            do { try await installer.complete() }
            catch { NSLog("Lino installed and opened; previous bundle cleanup deferred: %@", error.localizedDescription) }
        } catch {
            try await installer.rollback()
            throw error
        }
    }
    func activateExistingApplication() { existingApplication?.activate(options: [.activateAllWindows]) }
    static func isInstalled(_ url: URL, home: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let locations = [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
        return locations.contains { folder in
            url.standardizedFileURL.path.hasPrefix(folder.path + "/") || resolved.path.hasPrefix(folder.path + "/") ||
                folder.appendingPathComponent("Lino.app").resolvingSymlinksInPath().standardizedFileURL == resolved
        }
    }
    var isDefault: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: Self.markdown)?.resolvingSymlinksInPath() == applicationURL.resolvingSymlinksInPath()
    }
    func makeDefault() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: Self.markdown) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
