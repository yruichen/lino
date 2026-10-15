import AppKit

/// AppKit owns sidebar, titlebar and tab-bar geometry. Only the editor's backing
/// canvas is kept wider than its visible pane to avoid repainting on reveal.
@MainActor
final class NavigationSplitView: NSSplitView {
    weak var controller: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private let sidebarClip = NSView()
    private var editorClip = NSView()
    private weak var sidebarContent: NSView?
    private weak var editorContent: NSView?
    private weak var footer: NSView?
    private var fixedBacking = true
    private var trackingDivider = false
    private var presentationSequence: UInt64 = 0
    var onSidebarSafeTop: ((CGFloat) -> Void)?
    private(set) var rememberedWidth: CGFloat = 268
    private(set) var expanded = false
    var onWidthChanged: ((CGFloat) -> Void)?
    var onViewportWidth: ((CGFloat) -> Void)?
    var onTransitionCompleted: (() -> Void)?
    var viewportWidth: CGFloat { editorClip.bounds.width }
    var editorPane: NSView { editorClip }
    var sidebarPane: NSView { sidebarClip }
    override var dividerColor: NSColor { ThemePalette.color("border") }

    func install(sidebar: NSView, editor: NSView, footer: NSView, pane: NSView, fixedBacking: Bool = true) {
        self.fixedBacking = fixedBacking; self.footer = footer; editorClip = pane
        sidebarContent = sidebar; editorContent = editor
        isVertical = true; dividerStyle = .thin
        wantsLayer = true; layer?.masksToBounds = true
        for clip in [sidebarClip, editorClip] { clip.wantsLayer = true; clip.layer?.masksToBounds = true }
        sidebarClip.addSubview(sidebar); editorClip.addSubview(editor); editorClip.addSubview(footer)
        let sidebarController = NSViewController(); sidebarController.view = sidebarClip
        let detailController = NSViewController(); detailController.view = editorClip
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 230; sidebarItem.maximumThickness = 360
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.allowsFullHeightLayout = true
        // Preserve the sidebar before the document on window resize, while
        // remaining below AppKit's divider-drag constraint priority (490).
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.canCollapse = false
        let detail = NSSplitViewItem(viewController: detailController)
        detail.minimumThickness = 320
        controller.addSplitViewItem(sidebarItem); controller.addSplitViewItem(detail)
    }
    func configure(width: CGFloat, expanded: Bool) {
        rememberedWidth = min(360, max(230, width)); self.expanded = expanded
        sidebarItem.isCollapsed = !expanded
        if expanded { layoutSubtreeIfNeeded(); setPosition(rememberedWidth, ofDividerAt: 0) }
    }
    func setRememberedWidth(_ width: CGFloat) {
        let value = min(360, max(230, width))
        guard value != rememberedWidth else { return }
        rememberedWidth = value
        if expanded {
            layoutSubtreeIfNeeded(); setPosition(value, ofDividerAt: 0)
            layoutPanes()
        }
    }
    func show(_ value: Bool, animated: Bool) {
        guard expanded != value else { layoutPanes(); return }
        expanded = value; presentationSequence &+= 1
        let sequence = presentationSequence
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0
            sidebarItem.animator().isCollapsed = !value
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentationSequence == sequence else { return }
                if self.expanded {
                    self.layoutSubtreeIfNeeded(); self.setPosition(self.rememberedWidth, ofDividerAt: 0)
                }
                self.layoutPanes(); self.onTransitionCompleted?()
            }
        }
    }
    func layoutPanes() {
        guard sidebarItem != nil else { return }
        // Safe-area insets come from the system's actual toolbar/tab layout,
        // independently for the full-height sidebar and document pane.
        let sidebarFrame = NSRect(x: 0, y: 0, width: max(rememberedWidth, sidebarClip.bounds.width), height: sidebarClip.bounds.height)
        if sidebarContent?.frame != sidebarFrame { sidebarContent?.frame = sidebarFrame }
        let safe = editorClip.safeAreaRect
        let footerFrame = NSRect(x: 0, y: safe.minY, width: editorClip.bounds.width, height: 30)
        if footer?.frame != footerFrame { footer?.frame = footerFrame }
        let offset = fixedBacking ? -(bounds.width - viewportWidth) / 2 : 0
        let editorFrame = NSRect(x: offset, y: footerFrame.maxY, width: fixedBacking ? bounds.width : viewportWidth, height: max(0, safe.maxY - footerFrame.maxY))
        if editorContent?.frame != editorFrame { editorContent?.frame = editorFrame }
        onViewportWidth?(viewportWidth)
        onSidebarSafeTop?(sidebarSafeTop)
    }
    var sidebarSafeTop: CGFloat { max(0, sidebarClip.bounds.maxY - sidebarClip.safeAreaRect.maxY) }
    override func adjustSubviews() { super.adjustSubviews(); layoutPanes() }
    override func layout() {
        super.layout(); layoutPanes()
        guard trackingDivider, expanded, sidebarItem != nil else { return }
        let width = sidebarClip.frame.width
        if width >= 230, width <= 360, abs(width - rememberedWidth) > 0.5 {
            rememberedWidth = width; onWidthChanged?(width)
        }
    }
    override func mouseDown(with event: NSEvent) {
        trackingDivider = true; defer { trackingDivider = false }
        super.mouseDown(with: event)
        layoutSubtreeIfNeeded(); layout()
    }
    func detach() { presentationSequence &+= 1; onWidthChanged = nil; onViewportWidth = nil; onTransitionCompleted = nil; onSidebarSafeTop = nil }
}
