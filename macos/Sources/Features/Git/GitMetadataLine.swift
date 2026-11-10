import AppKit

final class GitMetadataLine: NSView {
    struct Item {
        let text: String
        let value: String
        let label: String
        var highlights: [String] = []
    }
    private let first = InspectorMetadataText()
    private let second = InspectorMetadataText()
    private var firstNaturalWidth: CGFloat = 0
    private var secondNaturalWidth: CGFloat = 0
    var contextMenuProvider: (() -> NSMenu?)? {
        didSet { first.contextMenuProvider = contextMenuProvider; second.contextMenuProvider = contextMenuProvider }
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        [first, second].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ first: Item, second: Item?, onDoubleClick: @escaping () -> Void) {
        self.first.onDoubleClick = onDoubleClick
        self.second.onDoubleClick = onDoubleClick
        self.first.configure(text: first.text, value: first.value, label: first.label, highlights: first.highlights)
        if second == nil, window?.firstResponder === self.second { window?.makeFirstResponder(nil) }
        self.second.isHidden = second == nil
        if let second {
            self.second.configure(text: second.text, value: second.value, label: second.label, highlights: second.highlights)
        }
        firstNaturalWidth = self.first.naturalWidth
        secondNaturalWidth = self.second.naturalWidth
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let firstWidth = min(firstNaturalWidth, second.isHidden ? bounds.width : max(28, bounds.width * 0.44))
        first.frame = NSRect(x: 0, y: 0, width: firstWidth, height: bounds.height)
        second.frame = NSRect(x: firstWidth + 8, y: 0,
                              width: min(secondNaturalWidth, max(1, bounds.width - firstWidth - 8)), height: bounds.height)
    }
}
