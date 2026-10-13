import AppKit
import WebKit

@MainActor
func verifyCommandFlow(_ controller: EditorWindowController, settings: SettingsWindowController) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "CommandVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
    }
    guard let window = controller.window, let settingsWindow = settings.window else {
        throw NSError(domain: "CommandVerification", code: 2)
    }
    // Keep the fixture's document window alive through the remaining native
    // document checks; the runner owns application teardown after all stages.
    defer { settingsWindow.orderOut(nil) }
    // Only this isolated --verify application's own windows receive events.
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(controller.webView)
    // An accessory verification process starts inactive. Let AppKit complete
    // activation/key-window delivery before dispatching real menu equivalents.
    try await Task.sleep(for: .milliseconds(100))
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    let keyDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !controller.isActiveDocument && ContinuousClock.now < keyDeadline { try await Task.sleep(for: .milliseconds(20)) }
    window.makeFirstResponder(controller.webView)
    func snapshot() async throws -> [String: Any] { try await controller.bridge.call("snapshot") as? [String: Any] ?? [:] }
    func shortcut(_ key: String, code: UInt16) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
    }
    func mode(_ expected: String, segment: Int) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            let state = try await snapshot()
            let visible = window.toolbar?.items.first { $0.itemIdentifier == .editorMode }?.view as? NSSegmentedControl
            if state["mode"] as? String == expected && visible?.selectedSegment == segment && controller.modeControl.selectedSegment == segment { return true }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return false
    }
    try check("native-shortcut-document-window-key", controller.isActiveDocument)
    try check("native-command-1-dispatched", shortcut("1", code: 18))
    try check("native-command-1-engine-toolbar-sync", try await mode("visual", segment: 0))
    try check("native-command-2-dispatched", shortcut("2", code: 19))
    try check("native-command-2-engine-toolbar-sync", try await mode("source", segment: 1))
    try check("native-command-1-return-dispatched", shortcut("1", code: 18))
    try check("native-command-1-return-engine-toolbar-sync", try await mode("visual", segment: 0))
    try check("native-command-slash-dispatched", shortcut("/", code: 44))
    try check("native-command-slash-source-toolbar-sync", try await mode("source", segment: 1))
    try check("native-command-slash-return-dispatched", shortcut("/", code: 44))
    try check("native-command-slash-visual-toolbar-sync", try await mode("visual", segment: 0))

    func findCommand(_ name: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.representedObject as? String == name { return item }
            if let submenu = item.submenu, let result = findCommand(name, in: submenu) { return result }
        }
        return nil
    }
    guard let toolbar = window.toolbar?.items.first(where: { $0.itemIdentifier == .editorFormat }) as? NSMenuToolbarItem,
          let heading = findCommand("heading-3", in: toolbar.menu), let action = heading.action else {
        throw NSError(domain: "CommandVerification", code: 3)
    }
    try check("native-toolbar-heading-dispatched", NSApp.sendAction(action, to: heading.target, from: heading))
    let typed = try await controller.webView.callAsyncJavaScript("""
        const evidence = () => {
            const state = window.openTypora.snapshot(), selected = document.getSelection(), active = document.activeElement;
            return {
                text: state.text, selection: state.selection,
                focus: { document: document.hasFocus(), tag: active?.tagName ?? null,
                    name: active?.getAttribute('name') ?? null, className: active?.className ?? null },
                domSelection: { collapsed: selected?.isCollapsed ?? null,
                    anchorOffset: selected?.anchorOffset ?? null, focusOffset: selected?.focusOffset ?? null,
                    anchorText: selected?.anchorNode?.textContent?.slice(0, 120) ?? null,
                    focusText: selected?.focusNode?.textContent?.slice(0, 120) ?? null }
            };
        };
        const matches = (state, text, head) => state.text === text && state.selection.ranges.length === 1
            && state.selection.ranges[0].anchor === head && state.selection.ranges[0].head === head;
        const waitFor = async (text, head, deadline) => {
            let state = evidence();
            while (!matches(state, text, head) && performance.now() < deadline) {
                await new Promise(resolve => setTimeout(resolve, 10));
                state = evidence();
            }
            return state;
        };
        // Native sendAction accepts dispatch before the asynchronous WK command
        // completes. Wait for the command's actual text and caret postcondition.
        const initial = await waitFor('### ', 4, performance.now() + 1000);
        if (!matches(initial, '### ', 4)) return { ok: false, phase: 'heading-ready-timeout', initial, steps: [] };
        let expected = '### ', head = 4, ok = true;
        const steps = [], inputDeadline = performance.now() + 1000;
        for (const character of ['甲', '🙂', '乙']) {
            const accepted = document.execCommand('insertText', false, character);
            expected += character; head += character.length;
            // Do not reset focus/selection between characters: that would hide
            // the reversed-input/caret regression this fixture must detect.
            const state = await waitFor(expected, head, inputDeadline);
            const matched = matches(state, expected, head);
            steps.push({ character, accepted, matched, expected, head, state });
            ok = accepted && matched && ok;
        }
        return { ok, phase: 'continuous-input', initial, steps, final: evidence() };
        """, arguments: [:], in: nil, contentWorld: .page)
    guard let evidence = typed as? [String: Any], evidence["ok"] as? Bool == true else {
        var evidence = typed as? [String: Any] ?? ["invalidResult": String(describing: typed)]
        evidence["nativeFocus"] = ["documentKey": controller.isActiveDocument, "editorResponder": controller.editorHasKeyboardFocus,
            "responderType": String(describing: window.firstResponder.map { type(of: $0) })] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        throw NSError(domain: "CommandVerification", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "native-toolbar-heading-continuous-dom-input: " + (String(data: data, encoding: .utf8) ?? "Invalid evidence")])
    }
    try check("native-toolbar-heading-continuous-dom-input", true)

    let before = try await snapshot()
    settingsWindow.makeKeyAndOrderFront(nil)
    settingsWindow.makeFirstResponder(settings.languageControl)
    try check("native-settings-key-window-scope", NSApp.keyWindow === settingsWindow && !controller.isActiveDocument)
    for (key, code) in [("/", UInt16(44)), ("2", UInt16(19)), ("b", UInt16(11)), ("z", UInt16(6))] { _ = shortcut(key, code: code) }
    try await Task.sleep(for: .milliseconds(80))
    let after = try await snapshot()
    try check("native-settings-shortcuts-preserve-background-document", after["text"] as? String == before["text"] as? String
        && after["mode"] as? String == before["mode"] as? String && after["canUndo"] as? Bool == before["canUndo"] as? Bool)
    settingsWindow.orderOut(nil)
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(controller.webView)
    _ = try await controller.bridge.call("prepareReplacement")
    let discard = try await controller.bridge.call("replacementIntent", arguments: [true]) as? String
    let clean = try await controller.bridge.backend.perform { try $0.newDocument(replaceJson: discard) }
    _ = try await controller.bridge.call("attachDocument", arguments: [clean])
    return passed
}

@MainActor
func verifyInitialEditorSurface() throws -> [String] {
    let controller = EditorWindowController(verifying: true)
    defer { controller.detach() }
    guard controller.webView.isHidden, let window = controller.window, let surface = window.contentView else {
        throw NSError(domain: "SurfaceVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Uninitialized WKWebView is visible"])
    }
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: name)
        surface.viewDidChangeEffectiveAppearance()
        let color = controller.webView.underPageBackgroundColor.usingColorSpace(.sRGB)
        let expected = name == .darkAqua ? CGFloat(32.0 / 255.0) : 1
        guard let color, abs(color.redComponent - expected) < 0.005, color.alphaComponent == 1 else {
            throw NSError(domain: "SurfaceVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native loading surface appearance mismatch"])
        }
    }
    return ["native-initial-webview-hidden", "native-light-dark-loading-surface"]
}
