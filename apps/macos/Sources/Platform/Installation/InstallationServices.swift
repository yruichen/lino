import AppKit
import UniformTypeIdentifiers

/// Launch Services owns file associations; these are machine settings, not document preferences.
@MainActor
final class InstallationServices {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    let applicationURL: URL
    init(applicationURL: URL = Bundle.main.bundleURL) { self.applicationURL = applicationURL }
    var installed: Bool { Self.isInstalled(applicationURL, home: FileManager.default.homeDirectoryForCurrentUser) }
    static func isInstalled(_ url: URL, home: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home.appendingPathComponent("Applications").path + "/")
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
    func showApplications() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true)) }
    func showPermissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!) }
}
