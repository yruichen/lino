import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Read-only native browsing. PDFKit and AppKit own rendering, selection,
/// scrolling and magnification; binary files never enter the Markdown session.
@MainActor
final class NativeFilePreview: NSObject {
    let view = NSView()
    private(set) var url: URL
    let focusView: NSView
    let pdf: PDFView?
    private let scroll: NSScrollView?
    private let ratio = NSTextField(labelWithString: "")
    private var scaleObserver: NSObjectProtocol?
    static func accepts(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .image)
    }
    init(url: URL) throws {
        self.url = url
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw NSError(domain: "Lino.Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("preview.invalid")]) }
        let renderer: NSView
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { throw NSError(domain: "Lino.Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("preview.invalid")]) }
            let pdf = PDFView(); self.pdf = pdf; scroll = nil
            pdf.document = document; pdf.autoScales = true
            pdf.displayMode = .singlePageContinuous; pdf.displaysPageBreaks = true
            pdf.backgroundColor = ThemePalette.color("bg")
            renderer = pdf
        } else {
            guard let image = NSImage(contentsOf: url), image.isValid else { throw NSError(domain: "Lino.Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("preview.invalid")]) }
            pdf = nil
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
            imageView.image = image; imageView.imageScaling = .scaleNone
            let scroll = NSScrollView(); self.scroll = scroll
            scroll.contentView = CenteredImageClipView()
            scroll.documentView = imageView; scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
            scroll.allowsMagnification = true; scroll.minMagnification = 0.1; scroll.maxMagnification = 8
            scroll.backgroundColor = ThemePalette.color("bg"); renderer = scroll
        }
        focusView = renderer
        super.init()
        ratio.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); ratio.textColor = .secondaryLabelColor
        let controls = NSStackView(); controls.spacing = 10; controls.alignment = .centerY
        for (symbol, action, key) in [("minus.magnifyingglass", #selector(smaller), "preview.smaller"), ("plus.magnifyingglass", #selector(larger), "preview.larger")] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: localized(key))!, target: self, action: action)
            button.identifier = NSUserInterfaceItemIdentifier(key)
            button.isBordered = false; button.toolTip = localized(key); controls.addArrangedSubview(button)
        }
        controls.addArrangedSubview(ratio)
        let fit = NSButton(title: localized("preview.fit"), target: self, action: #selector(fit)); fit.identifier = NSUserInterfaceItemIdentifier("preview.fit"); fit.bezelStyle = .inline
        let actual = NSButton(title: "100%", target: self, action: #selector(actual)); actual.bezelStyle = .inline
        controls.addArrangedSubview(fit); controls.addArrangedSubview(actual)
        for child in [renderer, controls] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.topAnchor, constant: 10), controls.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            renderer.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10), renderer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            renderer.leadingAnchor.constraint(equalTo: view.leadingAnchor), renderer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        if let pdf {
            scaleObserver = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdf, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateRatio() } }
        } else if let scroll {
            scaleObserver = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updateRatio() } }
        }
        updateRatio()
    }
    func bindCanonicalURL(_ url: URL) { self.url = url }
    func reload() throws {
        if let pdf {
            guard let document = PDFDocument(url: url) else { throw NSError(domain: "Lino.Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("preview.invalid")]) }
            pdf.document = document
        } else if let imageView = scroll?.documentView as? NSImageView {
            guard let image = NSImage(contentsOf: url), image.isValid else { throw NSError(domain: "Lino.Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("preview.invalid")]) }
            imageView.image = image; imageView.setFrameSize(image.size)
        }
    }
    func relocalize() {
        func update(_ view: NSView) {
            if let button = view as? NSButton, let key = button.identifier?.rawValue {
                button.toolTip = localized(key); button.setAccessibilityLabel(localized(key))
                if key == "preview.fit" { button.title = localized(key) }
            }
            for child in view.subviews { update(child) }
        }
        update(view); pdf?.backgroundColor = ThemePalette.color("bg"); scroll?.backgroundColor = ThemePalette.color("bg")
    }
    func prepare() { view.layoutSubtreeIfNeeded(); fit() }
    private func updateRatio() { ratio.stringValue = "\(Int(((pdf?.scaleFactor ?? scroll?.magnification ?? 1) * 100).rounded()))%" }
    private func scale(_ factor: CGFloat) {
        if let pdf { pdf.autoScales = false; pdf.scaleFactor = min(pdf.maxScaleFactor, max(pdf.minScaleFactor, factor)) }
        else if let scroll { scroll.magnification = min(scroll.maxMagnification, max(scroll.minMagnification, factor)) }
        updateRatio()
    }
    @objc private func smaller() { scale((pdf?.scaleFactor ?? scroll?.magnification ?? 1) / 1.25) }
    @objc private func larger() { scale((pdf?.scaleFactor ?? scroll?.magnification ?? 1) * 1.25) }
    @objc private func actual() { scale(1) }
    @objc private func fit() {
        if let pdf { pdf.autoScales = true; pdf.scaleFactor = pdf.scaleFactorForSizeToFit }
        else if let scroll, let image = scroll.documentView { scale(min(1, min(scroll.contentSize.width / max(1, image.frame.width), scroll.contentSize.height / max(1, image.frame.height)))) }
        updateRatio()
    }
    func detach() { if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver); self.scaleObserver = nil }; pdf?.document = nil }
}
