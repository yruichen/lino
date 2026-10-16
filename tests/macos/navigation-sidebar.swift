import AppKit

// The navigation fixtures use system colors; no user appearance preferences or
// application bundle are needed to exercise the real service and native tree.
@MainActor enum ThemePalette {
    static var navigationBackground: NSColor { .windowBackgroundColor }
    static func color(_ role: String) -> NSColor { .labelColor }
}
@MainActor final class ThemeSurface: NSBox {
    init(role: String, radius: CGFloat) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

@main struct Checks {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); exit(EXIT_SUCCESS) }
            catch { FileHandle.standardError.write(Data(("\(error)\n").utf8)); exit(EXIT_FAILURE) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("lino-sidebar-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Writing.md")
        try Data("# Writing\n".utf8).write(to: file)
        let navigation = NavigationCoordinator(backend: DocumentBackend())
        navigation.onError = { print("Navigation fixture error:", $0) }
        try await navigation.configure(verifying: true)
        let canonicalRoot = await navigation.addLocation(directory.path)!
        let filePath = canonicalRoot + "/Writing.md"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let workspace = WorkspaceController(navigation: navigation, window: window, verifying: true)
        window.contentView = workspace.view
        defer { workspace.detach(); navigation.detach(); window.close(); try? FileManager.default.removeItem(at: directory) }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard condition() else { throw NSError(domain: "SidebarCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture did not become ready"]) }
        }
        func rows() -> [NavigationItem] {
            (0..<workspace.outline.numberOfRows).compactMap { workspace.outline.item(atRow: $0) as? NavigationItem }
        }
        try await wait { rows().contains { $0.path == filePath } }
        if CommandLine.arguments.contains("--closed-layout") {
            let closingWindow = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 300, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            closingWindow.isReleasedWhenClosed = false
            var owner: WorkspaceController? = WorkspaceController(navigation: navigation, window: closingWindow, verifying: true)
            weak let releasedOwner = owner
            let retainedOutline = owner!.outline
            closingWindow.contentView = owner!.view
            closingWindow.makeKeyAndOrderFront(nil)
            try await wait { (0..<retainedOutline.numberOfRows).contains { (retainedOutline.item(atRow: $0) as? NavigationItem)?.path == filePath } }
            closingWindow.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            owner?.detach()
            precondition(retainedOutline.dataSource == nil && retainedOutline.delegate == nil && retainedOutline.numberOfRows == 0, "Detach left native row callbacks/cache alive beyond the workspace owner's lifetime")
            closingWindow.close(); owner = nil
            try await wait { releasedOwner == nil }
            retainedOutline.needsLayout = true; retainedOutline.layoutSubtreeIfNeeded()
            closingWindow.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            print("A closed window can retain and lay out its outline after the workspace owner is released.")
            return
        }
        if CommandLine.arguments.contains("--visible-layout") {
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            print("visible file rows before empty outline:", workspace.outline.numberOfRows)
            workspace.onOutlineVisibility = { _ in
                let expectedRows = workspace.showingOutline ? 0 : 2
                precondition(workspace.outline.numberOfRows == expectedRows, "The page callback observed the new data source with the previous native row cache")
                workspace.outline.needsLayout = true
                workspace.outline.layoutSubtreeIfNeeded()
            }
            workspace.setOutline(true)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            precondition(workspace.outline.numberOfRows == 0)
            workspace.setOutline(false)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            precondition(rows().contains { $0.path == filePath })
            navigation.sidebar.change { $0.outline = true }
            window.contentView?.layoutSubtreeIfNeeded()
            workspace.applyHeadings(["token": "populated", "complete": true, "entries": [["id": "heading", "from": 0, "level": 1, "title": "Writing"]]])
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(workspace.outline.numberOfRows == 1)
            workspace.applyHeadings(["token": "empty", "complete": true, "entries": [[String: Any]]()])
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(workspace.outline.numberOfRows == 0)
            navigation.sidebar.change { $0.outline = false }
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(rows().contains { $0.path == filePath })
            print("Visible file groups and an empty outline switch with consistent native row data.")
            return
        }
        func verifySort() async throws {
            let old = directory.appendingPathComponent("A-old.md"), new = directory.appendingPathComponent("Z-new.md")
            let folder = directory.appendingPathComponent("B-folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: folder.path)
            try Data("old".utf8).write(to: old); try Data("new".utf8).write(to: new)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: new.path)
            await navigation.change { $0.show_root = true }
            let root = rows().first { $0.section == nil && $0.path == canonicalRoot }!
            workspace.outline.expandItem(root)
            await navigation.refresh()
            func ordered() -> [NavigationItem] { rows().filter { ["A-old.md", "Z-new.md"].contains($0.title) } }
            try await wait { root.loaded && ordered().count == 2 }
            precondition(root.children.first?.directory == true, "Name sorting put a file before a directory")
            print("name order:", ordered().map(\.title), "timestamps:", ordered().map(\.modified))
            await navigation.change { $0.sort = "modified" }
            precondition(ordered().map(\.title) == ["Z-new.md", "A-old.md"], "Changing the sort setting did not immediately reorder already loaded rows")
            print("sort after shared commit:", navigation.values.sort, "visible order:", ordered().map(\.title))
            await navigation.refresh()
            try await wait { root.loaded }
            print("modified order after fresh Rust listing:", ordered().map(\.title), "timestamps:", ordered().map(\.modified))
            precondition(ordered().map(\.title) == ["Z-new.md", "A-old.md"], "The saved modified sort did not change the actual visible order")
            precondition(root.children.first?.directory == true, "Modified sorting put a newer file before a directory")
            workspace.outline.selectRowIndexes(IndexSet(integer: rows().firstIndex { $0.title == "A-old.md" }!), byExtendingSelection: false)
            func refreshSelectionChanges() async throws -> Int {
                var changes = 0
                let observer = NotificationCenter.default.addObserver(forName: NSOutlineView.selectionDidChangeNotification, object: workspace.outline, queue: .main) { _ in
                    MainActor.assumeIsolated { changes += 1 }
                }
                defer { NotificationCenter.default.removeObserver(observer) }
                await navigation.refresh()
                try await wait { root.loaded }
                return changes
            }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: old.path)
            _ = try await refreshSelectionChanges()
            precondition(ordered().map(\.title) == ["A-old.md", "Z-new.md"], "Equal modification times did not use stable name order")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: new.path)
            let changed = try await refreshSelectionChanges()
            precondition(changed > 0 && ordered().map(\.title) == ["Z-new.md", "A-old.md"], "Changed modification order never reached the native rows")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 4_000)], ofItemAtPath: new.path)
            let sameOrder = try await refreshSelectionChanges()
            precondition(sameOrder == 0, "A modification time that kept the same sort order recreated native rows")
            await navigation.change { $0.sort = "name" }
            precondition(ordered().map(\.title) == ["A-old.md", "Z-new.md"], "Switching back to name sort did not reorder cached rows")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5_000)], ofItemAtPath: old.path)
            let nameSave = try await refreshSelectionChanges()
            precondition(nameSave == 0, "Saving under name sort recreated unchanged native rows")
            print("Sorting applies immediately, keeps directories first, breaks modification ties by name, and only reloads when visible order changes.")
        }
        if CommandLine.arguments.contains("--sort") { try await verifySort(); return }
        func verifyCustomization() async throws {
            let studio = directory.appendingPathComponent("Studio")
            try FileManager.default.createDirectory(at: studio, withIntermediateDirectories: true)
            await navigation.addLocation(studio.path)
            let customization = SidebarCustomizationController(navigation: navigation)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func control(_ id: String) -> NSButton? {
                descendants(customization.view).first { $0.identifier?.rawValue == id } as? NSButton
            }
            let toggle = control("sidebar-group-recents")!
            let original = navigation.values.show_recents
            toggle.performClick(nil)
            try await wait { navigation.values.show_recents != original && control("sidebar-group-recents")?.isEnabled == true }
            precondition(control("sidebar-group-recents") === toggle, "Applying a sidebar preference replaced its control and lost keyboard/scroll continuity")
            precondition(control("sidebar-group-locations") != nil && control("group-up-locations") != nil)
            control("group-up-locations")?.performClick(nil)
            try await wait { navigation.values.sections.first == "locations" && control("sidebar-group-recents")?.isEnabled == true }
            precondition(!control("group-up-locations")!.isEnabled)
            let table = descendants(customization.view).first { $0.identifier?.rawValue == "sidebar-locations" } as! NSTableView
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            control("location-down")?.performClick(nil)
            try await wait { navigation.values.locations.last == canonicalRoot && control("sidebar-group-recents")?.isEnabled == true }
            precondition(table.selectedRow == 1, "Reordering a location lost the selected folder")
            control("remove-location")?.performClick(nil)
            try await wait { !navigation.values.locations.contains(canonicalRoot) && control("sidebar-group-recents")?.isEnabled == true }
            precondition(FileManager.default.fileExists(atPath: file.path), "Removing a sidebar location deleted its file")
            let saved = try JSONDecoder().decode(NavigationSnapshot.self, from: Data(try await navigation.backend.perform { try $0.navigation() }.utf8))
            precondition(saved.values == navigation.values, "The visible customization was not saved through the shared service")
            control("sidebar-customization-done")?.performClick(nil)
            print("Customization preserves controls, applies group order, keeps the selected folder while reordering, saves shared values, and never deletes removed folders.")
        }
        if CommandLine.arguments.contains("--customization") { try await verifyCustomization(); return }
        let baseline = rows().map(\.id)
        // Atomic content saves generate the same invalidation as other watcher
        // events. A pending listing must not erase the last complete tree.
        try Data("# Saved content\n".utf8).write(to: file, options: .atomic)
        await navigation.refresh()
        precondition(rows().map(\.id) == baseline, "Saving content emptied the visible sidebar while its directory was refreshed")
        print("Content-only refresh keeps the last complete sidebar visible.")
        try await wait { rows().contains { $0.path == filePath } }
        precondition(rows().first?.section == "locations", "Hiding the root folder also hid the independently configurable Locations group")
        print("Root-folder visibility preserves the configured Locations group.")
        await navigation.change { $0.show_root = true }
        let rootItem = rows().first { $0.section == nil && $0.path == canonicalRoot }!
        workspace.outline.expandItem(rootItem)
        try await wait { rootItem.loaded && rows().contains { $0.path == filePath } }
        workspace.outline.selectRowIndexes(IndexSet(integer: rows().firstIndex { $0.path == filePath }!), byExtendingSelection: false)
        var metadataSelectionChanges = 0
        let metadataObserver = NotificationCenter.default.addObserver(forName: NSOutlineView.selectionDidChangeNotification, object: workspace.outline, queue: .main) { _ in
            MainActor.assumeIsolated { metadataSelectionChanges += 1 }
        }
        try Data("# Saved again\n".utf8).write(to: file, options: .atomic)
        await navigation.refresh()
        try await wait { rootItem.loaded }
        NotificationCenter.default.removeObserver(metadataObserver)
        precondition(metadataSelectionChanges == 0, "A content-only save recreated native selection after its refreshed listing arrived")
        await navigation.change { $0.show_root = false }
        let added = directory.appendingPathComponent("Next.md")
        try Data("# Next\n".utf8).write(to: added)
        await navigation.refresh()
        try await wait { rows().contains { $0.path == canonicalRoot + "/Next.md" } }
        workspace.setCurrentFile(filePath)
        let otherRow = rows().firstIndex { $0.path == canonicalRoot + "/Next.md" }!
        workspace.outline.selectRowIndexes(IndexSet(integer: otherRow), byExtendingSelection: false)
        var selectionChanges = 0
        let selectionObserver = NotificationCenter.default.addObserver(forName: NSOutlineView.selectionDidChangeNotification, object: workspace.outline, queue: .main) { _ in
            MainActor.assumeIsolated { selectionChanges += 1 }
        }
        await navigation.noteFile(filePath)
        NotificationCenter.default.removeObserver(selectionObserver)
        precondition(selectionChanges == 0, "Updating hidden recent files reloaded the unrelated native tree selection")
        await navigation.change { $0.follow_active = true }
        precondition((workspace.outline.item(atRow: workspace.outline.selectedRow) as? NavigationItem)?.path == filePath, "Enabling Follow Active File did not select the already visible current file")
        try FileManager.default.removeItem(at: file)
        await navigation.refresh()
        try await wait { !rows().contains { $0.path == filePath } }
        print("Real directory additions/removals and enabling Follow Active File reach the visible tree; hidden recents preserve selection.")
        try Data("# Writing\n".utf8).write(to: file)
        try await verifySort()
        try await verifyCustomization()
    }
}
