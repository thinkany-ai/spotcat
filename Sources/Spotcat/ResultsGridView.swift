import AppKit

struct ResultSection {
    let title: String
    let detail: String?
    let items: [LauncherItem]
}

enum GridDirection {
    case left, right, up, down
}

/// 分区的图标网格：区块标题 + 每行固定列数的「图标在上、名称在下」格子。
/// 格子视图复用，避免每次按键重建大量视图。
final class ResultsGridView: NSView {
    enum Metrics {
        static let columns = 9
        static let horizontalPadding: CGFloat = 12
        static let tileHeight: CGFloat = 92
        static let headerHeight: CGFloat = 36
        static let sectionSpacing: CGFloat = 6
        static let bottomPadding: CGFloat = 10
    }

    var onActivate: ((LauncherItem) -> Void)?
    var iconProvider: ((LauncherItem) -> NSImage)?

    private(set) var items: [LauncherItem] = []
    private(set) var selectedIndex = 0
    private var tiles: [ResultTileView] = []
    private var headers: [SectionHeaderView] = []

    override var isFlipped: Bool { true }

    /// 重新布局，返回内容总高度
    /// keepSelection：同一次查询的结果补充到达时（如文件搜索），保持用户已选中的条目
    @discardableResult
    func update(sections: [ResultSection], width: CGFloat, keepSelection: Bool = false) -> CGFloat {
        let sections = sections.filter { !$0.items.isEmpty }
        let previousID = keepSelection && items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
        items = sections.flatMap(\.items)
        selectedIndex = previousID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0

        let tileWidth = floor((width - Metrics.horizontalPadding * 2) / CGFloat(Metrics.columns))
        var y: CGFloat = 0
        var tileIndex = 0

        for (sectionIndex, section) in sections.enumerated() {
            let header = header(at: sectionIndex)
            header.configure(title: section.title, detail: section.detail)
            header.frame = NSRect(x: Metrics.horizontalPadding, y: y, width: width - Metrics.horizontalPadding * 2, height: Metrics.headerHeight)
            header.isHidden = false
            y += Metrics.headerHeight

            for (i, item) in section.items.enumerated() {
                let tile = tile(at: tileIndex)
                let row = i / Metrics.columns
                let column = i % Metrics.columns
                tile.frame = NSRect(
                    x: Metrics.horizontalPadding + CGFloat(column) * tileWidth,
                    y: y + CGFloat(row) * Metrics.tileHeight,
                    width: tileWidth,
                    height: Metrics.tileHeight
                )
                tile.configure(name: item.name, icon: iconProvider?(item))
                tile.isSelected = tileIndex == selectedIndex
                tile.toolTip = item.toolTip
                tile.isHidden = false
                let index = tileIndex
                tile.onClick = { [weak self] in self?.activate(index: index) }
                tileIndex += 1
            }

            let rows = (section.items.count + Metrics.columns - 1) / Metrics.columns
            y += CGFloat(rows) * Metrics.tileHeight + Metrics.sectionSpacing
        }

        for tile in tiles[tileIndex...] { tile.isHidden = true }
        for header in headers[sections.count...] { header.isHidden = true }

        let height = sections.isEmpty ? 0 : y - Metrics.sectionSpacing + Metrics.bottomPadding
        setFrameSize(NSSize(width: width, height: height))
        if selectedIndex == 0 {
            scroll(.zero)
        } else {
            tiles[selectedIndex].scrollToVisible(tiles[selectedIndex].bounds)
        }
        return height
    }

    func moveSelection(_ direction: GridDirection) {
        guard !items.isEmpty else { return }
        let next: Int
        switch direction {
        case .left: next = max(selectedIndex - 1, 0)
        case .right: next = min(selectedIndex + 1, items.count - 1)
        case .up, .down: next = verticalNeighbor(of: selectedIndex, down: direction == .down) ?? selectedIndex
        }
        select(next)
    }

    func activateSelection() {
        activate(index: selectedIndex)
    }

    var selectedItem: LauncherItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    // MARK: - Private

    private func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        tiles[selectedIndex].isSelected = false
        selectedIndex = index
        tiles[index].isSelected = true
        // 露出一点上下文，滚到区块边缘时标题也能看见
        tiles[index].scrollToVisible(tiles[index].bounds.insetBy(dx: 0, dy: -Metrics.headerHeight))
    }

    private func activate(index: Int) {
        guard items.indices.contains(index) else { return }
        onActivate?(items[index])
    }

    /// 按几何位置找上一行/下一行中水平距离最近的格子，跨区块也能自然移动
    private func verticalNeighbor(of index: Int, down: Bool) -> Int? {
        let current = tiles[index].frame
        let candidates = (0..<items.count).filter { i in
            let frame = tiles[i].frame
            return down ? frame.minY >= current.maxY - 1 : frame.maxY <= current.minY + 1
        }
        guard let rowY = down
            ? candidates.map({ tiles[$0].frame.minY }).min()
            : candidates.map({ tiles[$0].frame.minY }).max()
        else { return nil }

        return candidates
            .filter { tiles[$0].frame.minY == rowY }
            .min { abs(tiles[$0].frame.midX - current.midX) < abs(tiles[$1].frame.midX - current.midX) }
    }

    private func tile(at index: Int) -> ResultTileView {
        while tiles.count <= index {
            let tile = ResultTileView()
            addSubview(tile)
            tiles.append(tile)
        }
        return tiles[index]
    }

    private func header(at index: Int) -> SectionHeaderView {
        while headers.count <= index {
            let header = SectionHeaderView()
            addSubview(header)
            headers.append(header)
        }
        return headers[index]
    }
}

final class SectionHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right
        addSubview(titleLabel)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(title: String, detail: String?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let labelHeight: CGFloat = 18
        let y = bounds.height - labelHeight - 6
        titleLabel.frame = NSRect(x: 4, y: y, width: bounds.width * 0.6, height: labelHeight)
        detailLabel.frame = NSRect(x: bounds.width * 0.6, y: y + 1, width: bounds.width * 0.4 - 4, height: labelHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ResultTileView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")

    var onClick: (() -> Void)?
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.cell?.truncatesLastVisibleLine = true

        addSubview(iconView)
        addSubview(nameLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(name: String, icon: NSImage?) {
        nameLabel.stringValue = name
        iconView.image = icon
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 40
        iconView.frame = NSRect(x: (bounds.width - iconSize) / 2, y: 10, width: iconSize, height: iconSize)
        nameLabel.frame = NSRect(x: 4, y: 56, width: bounds.width - 8, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    // 点击整块格子都算，子视图不拦截
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return NSMouseInRect(superview.convert(point, to: self), bounds, isFlipped) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
