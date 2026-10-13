import AppKit

/// A reusable native source-list row. The workspace service owns all data;
/// this view only presents a file name and an optional search excerpt.
@MainActor
final class WorkspaceRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("workspace-file-row")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseIdentifier
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, detail]); text.orientation = .vertical
        text.alignment = .leading; text.spacing = 2
        let row = NSStackView(views: [symbol, text]); row.spacing = 9; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 18), symbol.heightAnchor.constraint(equalToConstant: 18),
        ])
        textField = title; imageView = symbol
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(name: String, directory: Bool, excerpt: String? = nil) {
        title.stringValue = name; detail.stringValue = excerpt ?? ""; detail.isHidden = excerpt == nil
        symbol.image = NSImage(systemSymbolName: directory ? "folder" : "doc.text", accessibilityDescription: nil)
        symbol.contentTintColor = directory ? .controlAccentColor : .secondaryLabelColor
        toolTip = excerpt.map { name + "\n" + $0 } ?? name
        setAccessibilityLabel(toolTip)
    }
}
