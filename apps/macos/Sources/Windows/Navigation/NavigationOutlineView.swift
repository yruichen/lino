import AppKit

@MainActor
final class NavigationOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onOpen?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
final class NavigationItem {
    let id: String
    var title: String
    var path: String?
    var relative = ""
    var root: String?
    var directory = false
    var section: String?
    var children: [NavigationItem] = []
    var loaded = false
    var loading = false
    var modified: UInt64 = 0
    init(id: String, title: String) { self.id = id; self.title = title }
}

@MainActor
final class NavigationHeading {
    let id: String
    var from: Int
    var title: String
    var level: Int
    var children: [NavigationHeading] = []
    init(id: String, from: Int, title: String, level: Int) { self.id = id; self.from = from; self.title = title; self.level = level }
}

@MainActor
final class OutlineHeadingCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("outline-heading")
    private let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame); identifier = Self.reuseIdentifier
        label.lineBreakMode = .byTruncatingTail; label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label); textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(title: String, level: Int) {
        label.stringValue = title; label.font = .systemFont(ofSize: 13, weight: level == 1 ? .medium : .regular)
        toolTip = title; setAccessibilityLabel(title)
    }
}
