import Foundation

@main
struct ApplicationInstallerChecks {
    static func main() async throws {
        func check(_ condition: Bool) { precondition(condition) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lino-installer-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func app(_ path: String, _ text: String, identifier: String = "dev.open-typora.editor") throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Lino"], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            try Data(text.utf8).write(to: url.appendingPathComponent("Contents/version"))
            return url
        }
        func version(_ url: URL) throws -> String { try String(contentsOf: url.appendingPathComponent("Contents/version"), encoding: .utf8) }
        func noStaging(_ destination: URL) throws -> Bool { try !fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).contains { $0.hasPrefix(".lino-install-") } }
        let source = try app("Downloads/Lino.app", "new")
        let target = root.appendingPathComponent("Applications/Lino.app")
        let installer = ApplicationInstaller(source: source, destination: target, validate: { _ in })
        let installed = try await installer.install()
        precondition(installed == target)
        check(try version(target) == "new" && version(source) == "new")
        try await installer.complete()
        check(try noStaging(target))

        // A failed launch restores the previous app; source and unrelated files survive.
        try Data("old".utf8).write(to: target.appendingPathComponent("Contents/version"))
        try Data("document".utf8).write(to: root.appendingPathComponent("Applications/Note.md"))
        let replacement = ApplicationInstaller(source: source, destination: target, validate: { _ in })
        _ = try await replacement.install()
        check(try version(target) == "new")
        try await replacement.rollback()
        check(try version(target) == "old" && version(source) == "new" && noStaging(target))
        check(try String(contentsOf: root.appendingPathComponent("Applications/Note.md"), encoding: .utf8) == "document")

        let invalid = ApplicationInstaller(source: source, destination: target, validate: { _ in throw ApplicationInstallationError.invalidApplication })
        do { _ = try await invalid.install(); preconditionFailure("Invalid signature installed") } catch ApplicationInstallationError.invalidApplication {}
        check(try version(target) == "old" && noStaging(target))
        let invalidCopy = ApplicationInstaller(source: source, destination: target, validate: { url in
            if url.lastPathComponent == "Lino.app", url.deletingLastPathComponent().lastPathComponent.hasPrefix(".lino-install-") { throw ApplicationInstallationError.invalidApplication }
        })
        do { _ = try await invalidCopy.install(); preconditionFailure("Invalid copy installed") } catch ApplicationInstallationError.invalidApplication {}
        check(try version(target) == "old" && noStaging(target))

        let other = try app("Other/Lino.app", "other", identifier: "example.other")
        do { _ = try await ApplicationInstaller(source: source, destination: other, validate: { _ in }).install(); preconditionFailure("Unrelated app replaced") } catch ApplicationInstallationError.occupiedDestination {}
        check(try version(other) == "other")
        let alias = root.appendingPathComponent("Alias/Lino.app")
        try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: target)
        do { _ = try await ApplicationInstaller(source: source, destination: alias, validate: { _ in }).install(); preconditionFailure("Symlink destination replaced") } catch ApplicationInstallationError.occupiedDestination {}
        check(try version(target) == "old")

        // Reject a destination changed during staging, preserving the concurrent replacement.
        let changing = ApplicationInstaller(source: source, destination: target, validate: { url in
            if url.deletingLastPathComponent().lastPathComponent.hasPrefix(".lino-install-") {
                try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("moved.app"))
                try FileManager.default.copyItem(at: source, to: target)
            }
        })
        do { _ = try await changing.install(); preconditionFailure("Concurrent change overwritten") } catch ApplicationInstallationError.changedDestination {}
        check(try version(target) == "new" && version(root.appendingPathComponent("moved.app")) == "old" && noStaging(target))

        let running = ApplicationInstaller(source: source, destination: target, validate: { _ in })
        do { _ = try await running.install { throw ApplicationInstallationError.applicationRunning }; preconditionFailure("Running app replaced") } catch ApplicationInstallationError.applicationRunning {}
        check(try version(target) == "new" && noStaging(target))
        let cancellation = ApplicationInstaller(source: source, destination: target, validate: { _ in })
        let task = Task { try await cancellation.install() }; task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled install completed") } catch is CancellationError {}
        check(try version(target) == "new" && noStaging(target))
        let interrupted = ApplicationInstaller(source: source, destination: target, validate: { _ in })
        _ = try await interrupted.install()
        try fm.moveItem(at: target, to: root.appendingPathComponent("interrupted.app"))
        try fm.copyItem(at: source, to: target)
        do { try await interrupted.rollback(); preconditionFailure("Concurrent app deleted during rollback") }
        catch ApplicationInstallationError.cannotRestore(let backup) {
            check(try version(backup.appendingPathComponent("Previous.app")) == "new" && version(target) == "new")
        }
        // The real verifier rejects an unsigned fixture rather than silently skipping validation.
        do { try ApplicationInstaller.verifySignature(source); preconditionFailure("Unsigned app accepted") } catch ApplicationInstallationError.invalidApplication {}
        if let index = CommandLine.arguments.firstIndex(of: "--signed-app"), CommandLine.arguments.indices.contains(index + 1) {
            let signed = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let destination = root.appendingPathComponent("Signed/Lino.app")
            let installer = ApplicationInstaller(source: signed, destination: destination)
            _ = try await installer.install()
            try ApplicationInstaller.verifySignature(destination)
            try await installer.rollback()
            precondition(!fm.fileExists(atPath: destination.path))
            try ApplicationInstaller.verifySignature(signed)
            print("Signed production bundle: copied, validated and rolled back in a temporary directory.")
        }
        print("Application installer: installation, rollback, signature validation, running app, cancellation and concurrent replacement protection passed.")
    }
}
