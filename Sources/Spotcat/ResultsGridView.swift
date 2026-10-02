import AppKit

struct ResultSection {
    enum Layout {
        /// 图标格子，每行固定列数
        case tiles
        /// 每项占一整行的卡片（内置扩展的即时结果）
        case wide
        /// 每项占一整行的紧凑列表（扩展提供的内容，如笔记）
        case list
    }

    let title: String
    let detail: String?
    let items: [LauncherItem]
    var layout: Layout = .tiles
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
        static let tileHeight: CGFloat = 80
        static let wideHeight: CGFloat = 72
        static let listHeight: CGFloat = 44
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

            let rowHeight: CGFloat? = section.layout == .wide ? Metrics.wideHeight : section.layout == .list ? Metrics.listHeight : nil
            for (i, item) in section.items.enumerated() {
                let tile = tile(at: tileIndex)
                if let rowHeight {
                    tile.frame = NSRect(x: Metrics.horizontalPadding, y: y + CGFloat(i) * rowHeight,
                                        width: width - Metrics.horizontalPadding * 2, height: rowHeight)
                } else {
                    let row = i / Metrics.columns
                    let column = i % Metrics.columns
                    tile.frame = NSRect(
                        x: Metrics.horizontalPadding + CGFloat(column) * tileWidth,
                        y: y + CGFloat(row) * Metrics.tileHeight,
                        width: tileWidth,
                        height: Metrics.tileHeight
                    )
                }
                if case .answer(let answer) = item {
                    tile.configure(answer: answer, icon: iconProvider?(item))
                } else if section.layout == .list, case .indexed(let ref) = item {
                    tile.configure(row: ref.item.title, subtitle: ref.item.subtitle, icon: iconProvider?(item))
                } else {
                    tile.configure(name: item.name, icon: iconProvider?(item))
                }
                tile.isSelected = tileIndex == selectedIndex
                tile.toolTip = item.toolTip
                tile.isHidden = false
                let index = tileIndex
                tile.onClick = { [weak self] in self?.activate(index: index) }
                tileIndex += 1
            }

            if let rowHeight {
                y += CGFloat(section.items.count) * rowHeight + Metrics.sectionSpacing
            } else {
                let rows = (section.items.count + Metrics.columns - 1) / Metrics.columns
                y += CGFloat(rows) * Metrics.tileHeight + Metrics.sectionSpacing
            }
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

        let row = candidates.filter { tiles[$0].frame.minY == rowY }
        // 从整行卡片往下走时落到第一列，而不是正中间的格子
        if current.width > tiles[row[0]].frame.width * 2 { return row.min() }
        return row.min { abs(tiles[$0].frame.midX - current.midX) < abs(tiles[$1].frame.midX - current.midX) }
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
    private let nameLabel = NSTextField(labelWithString: "")
    /// 整行卡片的副标题（如算式）
    private let subtitleLabel = NSTextField(labelWithString: "")
    private enum Style { case tile, answer, row }
    private var style = Style.tile
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

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
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = true

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(name: String, icon: NSImage?) {
        isHovered = false
        style = .tile
        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = true
        toolTip = name
        iconView.image = icon
        needsLayout = true
    }

    /// 整行卡片：左边图标，副标题在上、结果大字在下
    func configure(answer: BuiltinAnswer, icon: NSImage?) {
        isHovered = false
        style = .answer
        nameLabel.stringValue = answer.title
        nameLabel.font = .systemFont(ofSize: 24, weight: .medium)
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.stringValue = answer.subtitle
        subtitleLabel.isHidden = false
        toolTip = answer.title
        iconView.image = icon
        needsLayout = true
    }

    /// 紧凑列表行：小图标，标题和副标题在同一行
    func configure(row title: String, subtitle: String?, icon: NSImage?) {
        isHovered = false
        style = .row
        nameLabel.stringValue = title
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        toolTip = [title, subtitle].compactMap { $0 }.joined(separator: "\n")
        iconView.image = icon
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if style == .row {
            let iconSize: CGFloat = 24
            iconView.frame = NSRect(x: 14, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            let textX = iconView.frame.maxX + 12
            let available = bounds.width - textX - 16
            let textWidth = ceil(nameLabel.attributedStringValue.size().width) + 6
            let titleWidth = subtitleLabel.isHidden ? available : min(textWidth, available * 0.6)
            nameLabel.frame = NSRect(x: textX, y: (bounds.height - 18) / 2, width: titleWidth, height: 18)
            subtitleLabel.frame = NSRect(x: textX + titleWidth + 12, y: (bounds.height - 16) / 2 + 1,
                                         width: max(0, available - titleWidth - 12), height: 16)
        } else if style == .answer {
            let iconSize: CGFloat = 40
            iconView.frame = NSRect(x: 14, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            let textX = iconView.frame.maxX + 14
            let textWidth = bounds.width - textX - 16
            subtitleLabel.frame = NSRect(x: textX, y: 10, width: textWidth, height: 16)
            nameLabel.frame = NSRect(x: textX, y: 28, width: textWidth, height: 32)
        } else {
            let iconSize: CGFloat = 40
            iconView.frame = NSRect(x: (bounds.width - iconSize) / 2, y: 10, width: iconSize, height: iconSize)
            nameLabel.frame = NSRect(x: 4, y: 56, width: bounds.width - 8, height: 16)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        // 搜索和滚动会移动复用的格子，同步鼠标当前位置，避免残留高亮。
        if !isHidden, let window, window.isVisible {
            isHovered = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            isHovered = false
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = !isHidden }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        NSColor.labelColor.withAlphaComponent(isSelected ? 0.1 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    // 点击整块格子都算，子视图不拦截
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 复用时隐藏的旧格子仍保留原位置，不能挡住移到这里的推荐项。
        guard !isHidden, let superview else { return nil }
        return NSMouseInRect(superview.convert(point, to: self), bounds, isFlipped) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
