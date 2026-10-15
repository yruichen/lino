import AppKit
import PDFKit

@MainActor
func verifyUpgrade(_ windows: DocumentWindows) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ value: Bool) throws {
        guard value else { throw NSError(domain: "UpgradeVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
        if CommandLine.arguments.contains("--headless") { FileHandle.standardError.write(Data((name + "\n").utf8)) }
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw NSError(domain: "UpgradeVerification", code: 2) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-upgrade-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let picture = directory.appendingPathComponent("Figure.png"), note = directory.appendingPathComponent("Writing.md"), other = directory.appendingPathComponent("Other.md")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 400, height: 240).fill(); NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: picture)
    let text = "# Writing\n\nText before ![Alternative](Figure.png \"A useful caption\") text after\n\n```mermaid\nflowchart LR\nA-->B\n```\n\n```swift\nlet message = \"hello\"\n```\n"
    try Data(text.utf8).write(to: note); try Data("# Other\n".utf8).write(to: other)
    let originalNavigation = windows.navigation.values
    let originalSidebar = windows.navigation.sidebar.values
    let count = windows.controllers.count
    defer {
        for document in windows.controllers.dropFirst(count) { document.detach(); document.documents.cleanupVerificationFiles(); document.window?.delegate = nil; document.window?.close() }
        try? FileManager.default.removeItem(at: directory)
    }
    if let root = await windows.navigation.addLocation(directory.path) { windows.navigation.sidebar.change { $0.workspace = root } }
    let document = windows.create(path: note.path)
    try await wait { document.documents.ready }
    guard let window = document.window else { throw ImageDataError.invalid }
    window.makeKeyAndOrderFront(nil); document.setWorkspaceVisible(true)
    let media = try await document.webView.callAsyncJavaScript("""
        for(const image of document.images) image.loading='eager';
        const deadline=Date.now()+10000;
        while(Date.now()<deadline){const image=document.querySelector('.ot-preview-image img'), diagram=document.querySelector('.ot-preview-diagram');if(image?.complete&&image.naturalWidth===400&&diagram?.dataset.previewState==='ready')break;await new Promise(r=>setTimeout(r,20));}
        const image=document.querySelector('.ot-preview-image img'), root=image?.closest('.ot-preview-image'), diagram=document.querySelector('.ot-preview-diagram'), svg=diagram?.querySelector('svg');
        window.upgradeImage=image; window.upgradeDiagram=svg;
        const r=diagram?.getBoundingClientRect(), s=svg?.getBoundingClientRect();
        const range=document.createRange(), line=root?.closest('.cm-line');
        const before=[...line.childNodes].find(n=>n.nodeType===3&&n.textContent.includes('Text before'));
        const after=[...line.childNodes].find(n=>n.nodeType===3&&n.textContent.includes('text after'));
        let flow=false;if(before&&after&&image){range.selectNodeContents(before);const b=range.getBoundingClientRect();range.selectNodeContents(after);const a=range.getBoundingClientRect(),i=root.getBoundingClientRect();flow=b.bottom<=i.top+1&&a.top>=i.bottom-1;}
        return {caption:root?.querySelector('.ot-image-caption')?.textContent==='A useful caption',scale:root?.dataset.imageScale==='1'&&!root.querySelector('.ot-image-scale'),flow,centered:!!r&&!!s&&Math.abs(r.left+r.width/2-s.left-s.width/2)<1};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool] ?? [:]
    try check("native-inline-image-breaks-text-flow-with-caption-and-no-size-label", media["caption"] == true && media["scale"] == true && media["flow"] == true)
    try check("native-mermaid-svg-is-centered-in-its-preview", media["centered"] == true)
    _ = try await document.bridge.call("navigateLine", arguments: [3])
    // Select the image through its rendered widget before invoking the native command.
    _ = try await document.webView.callAsyncJavaScript("document.querySelector('.ot-preview-image').dispatchEvent(new MouseEvent('click',{bubbles:true}));return true;", arguments: [:], in: nil, contentWorld: .page)
    _ = try await document.bridge.call("command", arguments: ["image-smaller"])
    let resized = try await document.webView.callAsyncJavaScript("const root=document.querySelector('.ot-preview-image');return root.querySelector('img')===window.upgradeImage&&root.dataset.imageScale==='0.8'&&!root.querySelector('.ot-image-scale')&&root.querySelector('img').style.width==='320px';", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    try check("native-image-resize-preserves-decoded-image-without-a-body-percentage", resized)
    let language = try await document.webView.callAsyncJavaScript("""
        [...document.querySelectorAll('.ot-code-language')].find(b=>b.textContent==='swift').click();
        const end=Date.now()+5000;
        const field=document.querySelector('[data-code-language-input]');field.focus();
        document.execCommand('selectAll');document.execCommand('insertText',false,'py');
        while(Date.now()<end){const item=[...document.querySelectorAll('.cm-tooltip-autocomplete li')].find(n=>n.textContent.includes('Python'));if(item){item.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));await new Promise(r=>setTimeout(r,20));return window.lino.snapshot().text.includes('```python');}await new Promise(r=>setTimeout(r,20));}return false;
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    try check("native-official-language-completion-applies-to-markdown-through-one-undo", language)
    _ = try await document.bridge.call("command", arguments: ["undo"])
    try check("native-save-completes", await document.documents.save())
    let stable = try await document.webView.callAsyncJavaScript("return document.querySelector('.ot-preview-image img')===window.upgradeImage&&document.querySelector('.ot-preview-diagram svg')===window.upgradeDiagram;", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    try check("native-save-preserves-loaded-image-and-mermaid-dom", stable)
    try await wait { document.externalState == "unchanged" }
    try check("native-save-does-not-publish-a-stale-external-change-warning", document.externalState == "unchanged")
    document.workspace.setOutline(true)
    await windows.open(path: other.path, origin: document)
    guard let target = windows.controllers.last, target !== document else { throw ImageDataError.invalid }
    try await wait { target.documents.ready }
    try check("tabs-share-sidebar-visibility-page-and-workspace", target.workspaceVisible && target.workspace.showingOutline && target.workspace.currentRoot == document.workspace.currentRoot)
    windows.navigation.sidebar.change { $0.width = 306 }
    try check("tabs-share-sidebar-width", target.navigationSplit.rememberedWidth == 306 && document.navigationSplit.rememberedWidth == 306)
    target.window?.contentView?.layoutSubtreeIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
    try check("tabs-share-the-actual-native-sidebar-width", abs(target.navigationSplit.sidebarPane.frame.width - 306) < 1 && abs(document.navigationSplit.sidebarPane.frame.width - 306) < 1)
    target.workspace.setOutline(false)
    try check("files-outline-switch-is-shared", !document.workspace.showingOutline)
    target.workspace.showContentSearch(); windows.navigation.contentSearch.changeQuery("Writing")
    try await wait { !windows.navigation.contentSearch.hits.isEmpty }
    try check("sidebar-content-search-has-one-shared-query-and-result-owner", windows.navigation.contentSearch.active && windows.navigation.contentSearch.query == "Writing")
    windows.navigation.contentSearch.close()
    target.window?.setContentSize(NSSize(width: 850, height: 600)); target.window?.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(120))
    window.tabGroup?.selectedWindow = window; window.makeKeyAndOrderFront(nil)
    let fitted = try await document.webView.callAsyncJavaScript("return Math.abs(document.querySelector('.cm-editor').getBoundingClientRect().width-width)<1&&document.querySelector('.ot-preview-image img')===window.upgradeImage;", arguments: ["width": document.navigationSplit.viewportWidth], in: nil, contentWorld: .page) as? Bool == true
    try check("resized-inactive-tab-keeps-loaded-content-and-current-viewport", fitted)
    document.quickOpen.show()
    try check("quick-open-uses-an-arrowless-native-child-panel", window.childWindows?.contains(where: { $0 is NSPanel }) == true && document.quickOpen.visible)
    document.quickOpen.dismiss()
    let header = window.contentLayoutGuide as! NSLayoutGuide
    try check("sidebar-extends-to-window-top-with-native-toolbar-separator", document.navigationSplit.frame.maxY == window.contentView!.bounds.maxY && header.frame.maxY < document.navigationSplit.frame.maxY && window.toolbar!.items.contains { $0 is NSTrackingSeparatorToolbarItem })
    let pane = document.navigationSplit.editorPane, safe = pane.safeAreaRect
    let editorTop = document.webView.convert(document.webView.bounds, to: window.contentView).maxY
    let safeTop = pane.convert(safe, to: window.contentView).maxY
    try check("native-tab-row-reserves-document-space-and-excludes-full-height-sidebar", document.navigationSplit.controller.splitViewItems.first?.allowsFullHeightLayout == true && editorTop <= safeTop + 0.5 && document.navigationSplit.sidebarSafeTop < pane.bounds.maxY - safe.maxY)
    let stateBeforeSidebar = try await document.bridge.call("snapshot") as! [String: Any]
    let frameBeforeSidebar = window.frame
    document.setWorkspaceVisible(false)
    try await wait { document.navigationSplit.controller.splitViewItems.first?.isCollapsed == true && target.navigationSplit.controller.splitViewItems.first?.isCollapsed == true && abs(document.navigationSplit.viewportWidth - document.navigationSplit.bounds.width) < 1 }
    try check("native-sidebar-collapse-reserves-the-full-document-pane-in-all-tabs", document.navigationSplit.controller.splitViewItems.first?.isCollapsed == true && target.navigationSplit.controller.splitViewItems.first?.isCollapsed == true && abs(document.navigationSplit.viewportWidth - document.navigationSplit.bounds.width) < 1)
    document.setWorkspaceVisible(true)
    try await Task.sleep(for: .milliseconds(45))
    document.setWorkspaceVisible(false)
    try await Task.sleep(for: .milliseconds(45))
    document.setWorkspaceVisible(true)
    try await wait { document.navigationSplit.controller.splitViewItems.first?.isCollapsed == false && abs(document.navigationSplit.sidebarPane.frame.width - 306) < 1 }
    let stateAfterSidebar = try await document.bridge.call("snapshot") as! [String: Any]
    let selectionBefore = try JSONSerialization.data(withJSONObject: stateBeforeSidebar["selection"]!, options: [.sortedKeys])
    let selectionAfter = try JSONSerialization.data(withJSONObject: stateAfterSidebar["selection"]!, options: [.sortedKeys])
    let stillLoaded = try await document.webView.callAsyncJavaScript("return document.querySelector('.ot-preview-image img')===window.upgradeImage&&document.querySelector('.ot-preview-diagram svg')===window.upgradeDiagram;", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    try check("native-sidebar-reversal-preserves-content-selection-media-and-window-frame", stateBeforeSidebar["text"] as? String == stateAfterSidebar["text"] as? String && selectionBefore == selectionAfter && stillLoaded && window.frame == frameBeforeSidebar && abs(document.navigationSplit.sidebarPane.frame.width - 306) < 1)
    _ = try await document.webView.callAsyncJavaScript("document.querySelector('.cm-scroller').scrollTop=0;await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return true;", arguments: [:], in: nil, contentWorld: .page)
    try await captureFixtureWindow(document, destination: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/upgrade.png"))
    await windows.open(path: picture.path, origin: document)
    guard let imagePreview = windows.controllers.last?.filePreview else { throw ImageDataError.invalid }
    try check("image-opens-in-a-native-readonly-tab-without-a-markdown-session", imagePreview.view.frame.width == windows.controllers.last?.navigationSplit.viewportWidth && imagePreview.pdf == nil && windows.controllers.last?.documents.sessionId == nil && windows.controllers.last?.isPreviewing == true)
    let pdf = directory.appendingPathComponent("Paper.pdf")
    let printable = PrintSurface(); try await printable.load("<html><body>A native PDF fixture</body></html>")
    guard await printable.print(in: window, info: NSPrintInfo.shared, pdf: pdf) else { throw ImageDataError.invalid }
    await windows.open(path: pdf.path, origin: document)
    try check("pdf-opens-with-pdfkit-in-a-native-readonly-tab", windows.controllers.last?.filePreview?.pdf?.document?.pageCount == 1 && windows.controllers.last?.documents.sessionId == nil)
    let withinRoot = windows.navigation.openFiles.filter { $0.hasPrefix(document.workspace.currentRoot! + "/") }
    try check("native-preview-path-uses-the-shared-canonical-workspace-identity", withinRoot.contains { $0.hasSuffix("Figure.png") })
    let previewCount = windows.controllers.count
    windows.controllers.last?.window?.performClose(nil)
    try check("readonly-preview-closes-without-save-or-unsaved-state", windows.controllers.count == previewCount - 1 && FileManager.default.fileExists(atPath: pdf.path))
    window.tabGroup?.selectedWindow = window; window.makeKeyAndOrderFront(nil)
    let layout = try await document.webView.callAsyncJavaScript("return await window.lino.verifyMediaLayout();", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
    for name in layout["passed"] as? [String] ?? [] { try check(name, true) }
    for name in layout["failed"] as? [String] ?? [] { try check(name, false) }
    try check("media-layout-fixture-returned-results", !(layout["passed"] as? [String] ?? []).isEmpty)
    await windows.navigation.change { $0 = originalNavigation }
    windows.navigation.sidebar.change { $0 = originalSidebar }
    return passed
}
