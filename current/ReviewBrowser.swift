import AppKit

final class ReviewKeyWindow: NSWindow {
    var navigate: ((Bool) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, [123, 124].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           !(firstResponder is NSTextView), !(firstResponder is NSPopUpButton),
           !(firstResponder is NSSlider) {
            navigate?(event.keyCode == 124); return
        }
        super.sendEvent(event)
    }
}

final class AnnotatedPhotoView: NoteActionsImageView {
    var marking = false
    var points: [PhotoAnnotation] = [] { didSet { needsDisplay = true } }
    var onMark: ((Double, Double) -> Void)?
    var imageRect: NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func mouseDown(with event: NSEvent) {
        guard marking else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return }
        let y = (point.y - rect.minY) / rect.height
        onMark?(Double((point.x - rect.minX) / rect.width), Double(isFlipped ? y : 1 - y))
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = imageRect
        for (index, point) in points.enumerated() {
            let center = NSPoint(x: rect.minX + rect.width * point.x,
                y: rect.minY + rect.height * (isFlipped ? point.y : 1 - point.y))
            let circle = NSRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)
            Memphis.pink.setFill(); NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke(); let outline = NSBezierPath(ovalIn: circle); outline.lineWidth = 2; outline.stroke()
            let text = "\(index + 1)" as NSString
            text.draw(at: NSPoint(x: center.x - 4, y: center.y - 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
        }
    }
}

final class PhotoBrowserCell: NSCollectionViewItem {
    let preview = NSImageView()
    let name = label("", 11, .medium)
    let state = label("", 10, .regular, .secondaryLabelColor)
    var recordID = ""
    var loading: PreviewTicket?
    override var isSelected: Bool { didSet { updateBorder() } }
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 4
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor(hex: 0x242424).cgColor
        name.maximumNumberOfLines = 1; name.lineBreakMode = .byTruncatingMiddle
        state.maximumNumberOfLines = 1; state.lineBreakMode = .byTruncatingTail
        let stack = column([preview, name, state], spacing: 5)
        view.addSubview(stack); pin(stack, to: view, inset: 6); fullWidth(stack.arrangedSubviews, in: stack)
        preview.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: -38).isActive = true
        updateBorder()
    }
    private func updateBorder() {
        view.layer?.borderWidth = isSelected ? 3 : 1
        view.layer?.borderColor = (isSelected ? Memphis.pink : Memphis.ink.withAlphaComponent(0.12)).cgColor
        view.layer?.backgroundColor = NSColor.white.cgColor
    }
    override func prepareForReuse() { super.prepareForReuse(); loading?.cancel(); loading = nil; recordID = ""; preview.image = nil }
}

final class CategoryBrowserRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Memphis.mint.withAlphaComponent(0.6).setFill()
        bounds.insetBy(dx: 2, dy: 2).fill()
    }
}

final class ReviewBrowser: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var owner: ReviewWindow?
    let collection = ReviewPhotoCollection()
    let table = NSTableView()
    let gridScroll = NSScrollView()
    let categoriesScroll = NSScrollView()
    let search = NSSearchField()
    let sort = NSPopUpButton()
    let size = NSSlider(value: 156, minValue: 128, maxValue: 224, target: nil, action: nil)
    var groupCounts = [GroupReviewSection: Int]()
    var counts = [PhotoCategory: Int]()
    var total = 0
    private var updating = false
    init(owner: ReviewWindow) {
        self.owner = owner; super.init()
        collection.noteContextAt = { [weak owner] path in
            guard let owner,owner.visible.indices.contains(path.item),let note = owner.onPhotoNote else { return nil }
            let record = owner.visible[path.item]
            return PhotoNoteMenuContext(files:record.sources.map { URL(fileURLWithPath:$0) },note: { note(record) })
        }
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 156, height: 156); layout.minimumInteritemSpacing = 10; layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = layout; collection.isSelectable = true
        collection.backgroundColors = [.clear]; collection.dataSource = self; collection.delegate = self
        collection.register(PhotoBrowserCell.self, forItemWithIdentifier: .init("photo"))
        gridScroll.documentView = collection; gridScroll.hasVerticalScroller = true; gridScroll.drawsBackground = false
        let col = NSTableColumn(identifier: .init("category")); table.addTableColumn(col)
        table.headerView = nil; table.rowHeight = 43; table.style = .sourceList
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        categoriesScroll.documentView = table; categoriesScroll.hasVerticalScroller = true; categoriesScroll.drawsBackground = false
        search.placeholderString = "搜索文件名或识别内容"; search.delegate = self
        search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        sort.addItems(withTitles: ["文件顺序", "文件名", "先看待决定", "先看已反馈"])
        sort.target = owner; sort.action = #selector(ReviewWindow.changeSort)
        size.target = self; size.action = #selector(resizeGrid); size.toolTip = "缩略图大小"
        size.widthAnchor.constraint(equalToConstant: 100).isActive = true
    }
    func update(reload: Bool) {
        guard let owner else { return }
        guard !updating else { return }
        updating = true; defer { updating = false }
        if reload {
            total = owner.records.count; counts = [:]
            for photo in owner.plan.photos { counts[photo.choice.selected ? photo.choice.category : .unassigned, default: 0] += 1 }
            counts[.unassigned, default: 0] += max(0, total - owner.plan.photos.count)
            groupCounts = [:]
            if owner.plan.mode == .groups { for record in owner.records { groupCounts[owner.groupSection(for: record), default: 0] += 1 }; groupCounts[.all] = owner.records.count }
            table.reloadData(); table.selectRowIndexes(IndexSet(integer: owner.plan.mode == .groups ? (owner.filter.selectedSegment == 1 ? GroupReviewSection.all.rawValue : owner.groupSection.rawValue) : owner.categoryFilter.indexOfSelectedItem), byExtendingSelection: false)
            collection.reloadData()
        }
        if let current = owner.current, let index = owner.visible.firstIndex(where: { $0.id == current.id }) {
            let path = IndexPath(item: index, section: 0)
            collection.layoutSubtreeIfNeeded()
            collection.selectionIndexPaths = [path]
            collection.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
            if let rect = collection.layoutAttributesForItem(at: path)?.frame,
               !collection.visibleRect.contains(rect) {
                collection.scrollToVisible(rect)
            }
        } else { collection.selectionIndexPaths = [] }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { owner?.plan.mode == .groups ? GroupReviewSection.allCases.count : PhotoCategory.allCases.count + 1 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title: String, count: Int
        if owner?.plan.mode == .groups, let section = GroupReviewSection(rawValue: row) { title = section.title; count = groupCounts[section, default: 0] }
        else if row == 0 { title = "全部照片"; count = total }
        else { let category = PhotoCategory.allCases[row - 1]; title = category.title; count = counts[category, default: 0] }
        let name = label(title, 11, .medium); name.maximumNumberOfLines = 2
        let number = label(String(count), 11, .semibold, .secondaryLabelColor)
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        let view = rowView(name, number)
        return view
    }
    private func rowView(_ name: NSView, _ count: NSView) -> NSView {
        let result = NSView(), content = row([name, spacer(), count], spacing: 5)
        result.addSubview(content); pin(content, to: result, inset: 5); return result
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let owner, table.selectedRow >= 0 else { return }
        if owner.plan.mode == .groups, let section = GroupReviewSection(rawValue: table.selectedRow) {
            guard owner.groupSection != section || owner.filter.selectedSegment != 0 else { return }
            owner.groupSection = section; owner.filter.selectedSegment = 0; owner.changeFilter(); return
        }
        guard owner.categoryFilter.indexOfSelectedItem != table.selectedRow else { return }
        owner.categoryFilter.selectItem(at: table.selectedRow); owner.changeFilter()
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CategoryBrowserRow() }
    func controlTextDidChange(_ obj: Notification) { owner?.changeFilter() }
    @objc func resizeGrid() {
        guard let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        layout.itemSize = NSSize(width: size.doubleValue, height: size.doubleValue)
        layout.invalidateLayout()
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { owner?.visible.count ?? 0 }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: .init("photo"), for: indexPath) as! PhotoBrowserCell
        guard let owner, owner.visible.indices.contains(indexPath.item) else { return cell }
        let record = owner.visible[indexPath.item], id = record.id
        cell.recordID = id; cell.name.stringValue = URL(fileURLWithPath: record.preview).lastPathComponent
        let curated = owner.plan.photos.first { $0.recordID == id }
        let pending = owner.plan.exceptions.contains { $0.status == "pending" && $0.recordIDs.contains(id) }
        cell.state.stringValue = (curated == nil ? "尚未识别 · " : pending ? "待决定 · " : curated?.source == "user" ? "已反馈 · " : curated?.source == "local_memory" ? "本场经验 · " : "")
            + (owner.plan.mode == .groups ? owner.groupSection(for: record).title : curated?.choice.selected == true ? curated!.choice.category.title : PhotoCategory.unassigned.title)
        cell.view.toolTip = cell.name.stringValue + "\n" + cell.state.stringValue
        cell.loading?.cancel(); cell.preview.image = nil
        cell.loading = owner.previewLoader.request(record, pixels: 400) { [weak cell] image in
            if cell?.recordID == id { cell?.preview.image = image }
        }
        return cell
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let owner, let path = indexPaths.first, owner.visible.indices.contains(path.item), path.item != owner.index else { return }
        owner.stashReason(); owner.index = path.item; owner.display()
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? PhotoBrowserCell)?.loading?.cancel()
    }
}
