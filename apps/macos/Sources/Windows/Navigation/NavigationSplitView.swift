import AppKit

/// One split position drives both native surfaces, including reversals.
@MainActor
final class NavigationSplitView: NSSplitView, NSSplitViewDelegate {
    private var transition: SidebarWidthAnimation?
    private var applying = false
    private var position: CGFloat = 0
    private let sidebarClip = NSView()
    private let editorClip = NSView()
    private weak var sidebarContent: NSView?
    private weak var editorContent: NSView?
    private(set) var rememberedWidth: CGFloat = 268
    var onWidthChanged: ((CGFloat) -> Void)?
    var onViewportWidth: ((CGFloat) -> Void)?
    var onTransitionCompleted: (() -> Void)?
    private(set) var expanded = false
    override var dividerThickness: CGFloat { position > 0 ? super.dividerThickness : 0 }
    override var dividerColor: NSColor { ThemePalette.color("border") }
    override func drawDivider(in rect: NSRect) { if position > 0 { super.drawDivider(in: rect) } }
    var viewportWidth: CGFloat {
        let width = min(position, maximumWidth)
        return max(0, bounds.width - width - (width > 0 ? dividerThickness : 0))
    }
    func install(sidebar: NSView, editor: NSView) {
        wantsLayer = true; layer?.masksToBounds = true
        sidebarClip.wantsLayer = true; sidebarClip.layer?.masksToBounds = true
        editorClip.wantsLayer = true; editorClip.layer?.masksToBounds = true
        sidebarContent = sidebar; sidebarClip.addSubview(sidebar)
        editorContent = editor; editorClip.addSubview(editor)
        addSubview(sidebarClip); addSubview(editorClip)
    }
    var maximumWidth: CGFloat { min(360, max(230, bounds.width - 320 - dividerThickness)) }
    func configure(width: CGFloat, expanded: Bool) {
        isVertical = true; dividerStyle = .thin; delegate = self
        rememberedWidth = min(360, max(230, width)); self.expanded = expanded
        position = expanded ? rememberedWidth : 0
        adjustSubviews()
    }
    func show(_ value: Bool, animated: Bool) {
        transition?.stop(); transition = nil; expanded = value
        let target = value ? rememberedWidth : 0
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(target - position) > 0.5 else { apply(target); onTransitionCompleted?(); return }
        let animation = SidebarWidthAnimation(from: position, to: target, duration: value ? 0.18 : 0.16) { [weak self] width, finished in
            self?.apply(width)
            if finished { self?.onTransitionCompleted?() }
        }
        transition = animation; animation.start()
    }
    private func apply(_ width: CGFloat) {
        position = width; adjustSubviews()
    }
    func detach() {
        transition?.stop(); transition = nil
        onWidthChanged = nil; onViewportWidth = nil; onTransitionCompleted = nil
    }
    override func adjustSubviews() {
        guard subviews.count == 2, bounds.width > 0 else { return }
        applying = true; defer { applying = false }
        let width = min(position, maximumWidth), divider: CGFloat = width > 0 ? dividerThickness : 0
        sidebarContent?.frame = NSRect(x: 0, y: 0, width: min(rememberedWidth, maximumWidth), height: bounds.height)
        subviews[0].isHidden = width <= 0
        subviews[0].frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        // WebKit paints asynchronously. Keep its backing surface at window width
        // during a reveal; only the native origin and the visible CSS viewport move.
        // The clipped extra backing area covers the right edge throughout animation.
        editorClip.frame = NSRect(x: width + divider, y: 0, width: viewportWidth, height: bounds.height)
        // Center the fixed backing canvas on the visible pane. CSS can reflow
        // asynchronously, but its center never moves relative to this canvas.
        editorContent?.frame = NSRect(x: -(width + divider) / 2, y: 0, width: bounds.width, height: bounds.height)
        onViewportWidth?(viewportWidth)
        needsDisplay = true
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { adjustSubviews() }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { expanded ? 230 : 0 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { expanded ? maximumWidth : 0 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { position <= 0 }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applying, transition?.isAnimating != true, expanded, subviews.count == 2 else { return }
        transition?.stop(); transition = nil
        position = min(maximumWidth, max(230, subviews[0].frame.width))
        rememberedWidth = position; adjustSubviews(); onWidthChanged?(position)
    }
}

@MainActor
private final class SidebarWidthAnimation: NSAnimation {
    private let from: CGFloat, to: CGFloat
    private let update: @MainActor @Sendable (CGFloat, Bool) -> Void
    init(from: CGFloat, to: CGFloat, duration: TimeInterval, update: @escaping @MainActor @Sendable (CGFloat, Bool) -> Void) {
        self.from = from; self.to = to; self.update = update
        super.init(duration: duration, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking; frameRate = 60
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set {
            super.currentProgress = newValue
            let callback = update, width = from + (to - from) * CGFloat(currentValue)
            MainActor.assumeIsolated { callback(width, newValue >= 1) }
        }
    }
}
