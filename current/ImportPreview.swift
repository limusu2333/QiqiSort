import AppKit

struct ImportSummary {
    let count: Int
    let photos: [[URL]]
    let errors: [String]

    static func load(_ inputs: [URL]) -> ImportSummary {
        let fm = FileManager.default
        var files = Set<URL>(), errors = [String]()
        func add(_ url: URL) {
            guard formats.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return }
            files.insert(url.standardizedFileURL)
        }
        for input in inputs {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: input.path, isDirectory: &directory) else {
                errors.append("输入不存在：\(input.path)"); continue
            }
            if directory.boolValue {
                let walk = fm.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                        errors.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true
                    })
                while let url = walk?.nextObject() as? URL {
                    if url.lastPathComponent.hasPrefix("合影筛选_") || url.lastPathComponent.hasPrefix("GATHER导出_")
                        || fm.fileExists(atPath: url.appendingPathComponent(".筛选记录/task.json").path) {
                        walk?.skipDescendants(); continue
                    }
                    add(url)
                }
            } else { add(input) }
        }
        let pairs = Dictionary(grouping: files, by: { $0.deletingPathExtension().path })
        let photos = pairs.keys.sorted().map { key in
            pairs[key]!.sorted {
                let a = ["jpg", "jpeg"].contains($0.pathExtension.lowercased())
                let b = ["jpg", "jpeg"].contains($1.pathExtension.lowercased())
                return a != b ? a : $0.path < $1.path
            }
        }
        return ImportSummary(count: pairs.count, photos: photos, errors: errors)
    }
}

final class ImportPreview: NSView {
    let placeholder = ImportArtwork()
    let scroll = FilmstripScrollView()
    let strip = ImportFilmstrip()
    private let back = NSButton(), next = NSButton()
    var images: [NSImage] { strip.visibleImages }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = strip; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false; scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        for (button, symbol, tip) in [(back, "chevron.left", "上一页照片"), (next, "chevron.right", "下一页照片")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .regularSquare; button.isBordered = false; button.toolTip = tip
            button.target = self; button.action = #selector(page(_:)); addSubview(button)
        }
        addSubview(scroll)
        addSubview(placeholder); placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: 160), placeholder.heightAnchor.constraint(equalToConstant: 104)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    func show(_ summary: ImportSummary?) {
        strip.show(summary?.photos ?? [])
        placeholder.isHidden = !strip.photos.isEmpty
        scroll.isHidden = strip.photos.isEmpty; back.isHidden = scroll.isHidden; next.isHidden = scroll.isHidden
        scroll.contentView.scroll(to: .zero); needsLayout = true; scrolled()
    }
    override func layout() {
        super.layout()
        back.frame = NSRect(x: 0, y: 28, width: 24, height: 32)
        next.frame = NSRect(x: bounds.width - 24, y: 28, width: 24, height: 32)
        scroll.frame = NSRect(x: 28, y: 0, width: max(1, bounds.width - 56), height: bounds.height)
        strip.frame.size = NSSize(width: max(scroll.contentSize.width, CGFloat(strip.photos.count) * strip.pitch), height: scroll.contentSize.height)
        scrolled()
    }
    @objc private func scrolled() {
        strip.needsDisplay = true
        back.isEnabled = scroll.contentView.bounds.minX > 0
        next.isEnabled = scroll.contentView.bounds.maxX < strip.bounds.width - 1
    }
    @objc private func page(_ sender: NSButton) {
        let x = scroll.contentView.bounds.minX + (sender === back ? -1 : 1) * scroll.contentSize.width
        scroll.contentView.scroll(to: NSPoint(x: min(max(0, x), max(0, strip.bounds.width - scroll.contentSize.width)), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView); scrolled()
    }
    func scrollToPhoto(_ index: Int) {
        let x = min(max(0, CGFloat(index) * strip.pitch), max(0, strip.bounds.width - scroll.contentSize.width))
        scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView); scrolled()
    }
}

final class FilmstripScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) < abs(event.scrollingDeltaY) else { super.scrollWheel(with: event); return }
        let x = contentView.bounds.minX - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        contentView.scroll(to: NSPoint(x: min(max(0, x), max(0, (documentView?.bounds.width ?? 0) - contentSize.width)), y: 0))
        reflectScrolledClipView(contentView)
    }
}

final class ImportFilmstrip: NSView {
    var gridMode = false { didSet { cache.countLimit = gridMode ? 200 : 48; cache.totalCostLimit = (gridMode ? 96 : 24) * 1024 * 1024 } }
    var pitch: CGFloat { gridMode ? 210 : 102 }
    var columns: Int { max(1, Int(bounds.width / pitch)) }
    var onNote: (([URL]) -> Void)?
    var onOpen: (([URL]) -> Void)?
    var noteFor: (([URL]) -> String?)?
    private var selected: Int?
    override var isFlipped: Bool { gridMode }
    func cell(_ index: Int) -> NSRect {
        gridMode ? NSRect(x: CGFloat(index % columns) * pitch, y: CGFloat(index / columns) * 190, width: pitch - 8, height: 184)
            : NSRect(x: CGFloat(index) * pitch, y: 0, width: pitch - 8, height: bounds.height)
    }
    func index(at point: NSPoint) -> Int? {
        let index = gridMode ? Int(max(0,point.y)/190) * columns + Int(max(0,point.x)/pitch) : Int(max(0,point.x)/pitch)
        return photos.indices.contains(index) && cell(index).contains(point) ? index : nil
    }
    override func mouseDown(with event: NSEvent) {
        selected = index(at: convert(event.locationInWindow, from: nil)); needsDisplay = true
        if event.clickCount == 2, let selected { onOpen?(photos[selected]) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        selected = index; needsDisplay = true
        return photoMenu(index)
    }
    func photoMenu(_ index: Int) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("放大查看", #selector(openPhoto(_:))), ("在访达中显示", #selector(revealPhoto(_:))), (noteFor?(photos[index]) == nil ? "添加备注…" : "编辑备注…", #selector(notePhoto(_:)))] {
            if action == #selector(notePhoto(_:)) && onNote == nil { continue }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.tag = index; item.representedObject = photos[index]; menu.addItem(item)
        }
        return menu
    }
    @objc private func openPhoto(_ item: NSMenuItem) { if let files = item.representedObject as? [URL] { onOpen?(files) } }
    @objc private func revealPhoto(_ item: NSMenuItem) { if let files = item.representedObject as? [URL] { NSWorkspace.shared.activateFileViewerSelecting(files) } }
    @objc private func notePhoto(_ item: NSMenuItem) { if let files = item.representedObject as? [URL] { onNote?(files) } }

    private(set) var photos = [[URL]]()
    private let cache = NSCache<NSNumber, NSImage>()
    private let queue = OperationQueue()
    private var pending = Set<Int>(), unreadable = Set<Int>(), generation = UUID()
    override init(frame: NSRect) {
        super.init(frame: frame)
        cache.countLimit = 48; cache.totalCostLimit = 24 * 1024 * 1024
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility
    }
    required init?(coder: NSCoder) { fatalError() }
    var visibleIndices: Range<Int> {
        if gridMode {
            let start = max(0, min(photos.count, Int(max(0,visibleRect.minY) / 190) * columns))
            return start..<max(start, min(photos.count, Int(ceil(visibleRect.maxY / 190)) * columns))
        }
        let start = max(0, min(photos.count, Int(visibleRect.minX / pitch)))
        let end = max(start, min(photos.count, Int(ceil(visibleRect.maxX / pitch))))
        return start..<end
    }
    var visibleImages: [NSImage] { visibleIndices.compactMap { cache.object(forKey: NSNumber(value: $0)) } }
    func update(_ photos: [[URL]]) {
        if self.photos.count <= photos.count && Array(photos.prefix(self.photos.count)) == self.photos {
            self.photos = photos; needsDisplay = true
        } else { show(photos) }
    }
    func show(_ photos: [[URL]]) {
        generation = UUID(); queue.cancelAllOperations(); pending.removeAll(); unreadable.removeAll(); cache.removeAllObjects()
        self.photos = photos; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        for index in visibleIndices {
            let outer = cell(index)
            let frame = gridMode ? NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: outer.height - 22) : NSRect(x: outer.minX, y: 16, width: outer.width, height: max(1, bounds.height - 16))
            Memphis.ink.setFill(); frame.fill()
            if let image = cache.object(forKey: NSNumber(value: index)) {
                let scale = min((frame.width - 6) / image.size.width, (frame.height - 6) / image.size.height)
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let symbol = NSImage(systemSymbolName: unreadable.contains(index) ? "exclamationmark.triangle" : "photo", accessibilityDescription: nil)
                symbol?.draw(in: NSRect(x: frame.midX - 10, y: frame.midY - 10, width: 20, height: 20))
            }
            if selected == index { Memphis.pink.setStroke(); let border = NSBezierPath(rect: frame.insetBy(dx: 1, dy: 1)); border.lineWidth = 3; border.stroke() }
            let name = (noteFor?(photos[index]) == nil ? "" : "● ") + (photos[index].first?.lastPathComponent ?? "")
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle; style.alignment = .center
            (name as NSString).draw(in: NSRect(x: frame.minX, y: gridMode ? frame.maxY + 3 : 0, width: frame.width, height: 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: Memphis.ink, .paragraphStyle: style])
        }
        // At most one viewport plus two neighbours is queued, even during fast scrolling.
        let visible = visibleIndices
        let wanted = Set(max(0, visible.lowerBound - 2)..<min(photos.count, visible.upperBound + 2))
        for operation in queue.operations {
            if let name = operation.name, let index = Int(name), !wanted.contains(index), !operation.isExecuting {
                operation.cancel(); pending.remove(index)
            }
        }
        for index in wanted.sorted() where cache.object(forKey: NSNumber(value: index)) == nil && !pending.contains(index) && !unreadable.contains(index) {
            pending.insert(index)
            let sources = photos[index], token = generation
            let operation = BlockOperation(); operation.name = String(index)
            operation.addExecutionBlock { [weak self, weak operation] in
                guard operation?.isCancelled == false else { return }
                // A lazy compactMap can evaluate the selected file twice. If the
                // source goes offline between those reads its internal unwrap traps.
                let bitmap = autoreleasepool { () -> CGImage? in
                    for source in sources {
                        guard operation?.isCancelled == false else { return nil }
                        if let image = try? PhotoImage.load(source, maxPixel: self?.gridMode == true ? 480 : 240) { return image }
                    }
                    return nil
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.pending.remove(index)
                    if let bitmap {
                        self.cache.setObject(NSImage(cgImage: bitmap, size: .zero), forKey: NSNumber(value: index), cost: bitmap.bytesPerRow * bitmap.height)
                    } else { self.unreadable.insert(index) }
                    self.needsDisplay = true
                }
            }
            queue.addOperation(operation)
        }
    }
}
