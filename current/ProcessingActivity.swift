import AppKit

struct ActivityItem {
    let text: String
    let key: String?
    let file: String
    let result: String
    let reason: String
    let color: NSColor
}
final class ActivityBadge: NSView {
    var title = "", color = Memphis.paper
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 7)
        color.setFill(); let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3); path.fill()
        Memphis.ink.withAlphaComponent(0.65).setStroke(); path.lineWidth = 0.8; path.stroke()
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:10,weight:.semibold),.foregroundColor:Memphis.ink]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at:NSPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2),withAttributes:attributes)
    }
}
final class ActivityRow: NSTableRowView {
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.activeInKeyWindow,.mouseEnteredAndExited,.inVisibleRect],owner:self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func drawBackground(in dirtyRect:NSRect) {
        (hovered ? Memphis.yellow.withAlphaComponent(0.12) : .white).setFill(); bounds.fill()
        Memphis.ink.withAlphaComponent(0.07).setFill(); NSRect(x:0,y:bounds.maxY-1,width:bounds.width,height:1).fill()
    }
    override func drawSelection(in dirtyRect:NSRect) {
        let rect = bounds.insetBy(dx:0,dy:2)
        Memphis.mint.withAlphaComponent(0.28).setFill(); rect.fill()
        Memphis.ink.withAlphaComponent(0.7).setStroke(); let border = NSBezierPath(rect:rect.insetBy(dx:0.5,dy:0.5)); border.lineWidth = 1; border.stroke()
        Memphis.ink.setFill(); NSRect(x:0,y:rect.minY,width:3,height:rect.height).fill()
    }
}
final class ProcessingLogView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    var entries = [String:ProcessingLogEntry]()
    private(set) var items = [ActivityItem]()
    var openEntry: ((ProcessingLogEntry)->Void)?
    var noteEntry: ((ProcessingLogEntry)->Void)?
    var correctEntry: ((ProcessingLogEntry)->Void)?
    private var batching = false
    var string: String {
        get { items.map(\.text).joined(separator:"\n") + "\n" }
        set {
            entries.removeAll(); items = newValue.split(separator:"\n").map { message(String($0)) }
            if !batching { reloadData() }
        }
    }
    override init(frame:NSRect) {
        super.init(frame:frame)
        headerView = nil; style = .fullWidth; rowHeight = 34; intercellSpacing = NSSize(width:8,height:0)
        backgroundColor = .white; selectionHighlightStyle = .regular
        dataSource = self; delegate = self; target = self; action = #selector(activateSelection)
        allowsEmptySelection = true; columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id,width) in [("file",180.0),("result",88.0),("reason",500.0),("open",22.0)] {
            let col = NSTableColumn(identifier:.init(id)); col.width = width
            col.minWidth = id == "reason" ? 80 : width
            col.maxWidth = id == "reason" ? 10000 : width
            col.resizingMask = id == "reason" ? [.autoresizingMask] : []
            addTableColumn(col)
        }
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }
    required init?(coder:NSCoder) { fatalError() }
    private func message(_ text:String)->ActivityItem {
        let stopped = text.contains("已停止") || text.contains("用户停止") || text.contains("正在结束")
        return ActivityItem(text:text,key:nil,file:stopped ? "任务状态" : "任务信息",result:stopped ? "已停止" : "",reason:text,color:Memphis.paper)
    }
    private func insert(_ item:ActivityItem) {
        items.append(item)
        if !batching { insertRows(at:IndexSet(integer:items.count-1),withAnimation:[]) }
    }
    func appendMessage(_ text:String) { insert(message(text)) }
    func performBatch(_ work:()->Void) { batching = true; work(); batching = false; reloadData() }
    func appendRecord(_ text:String, entry:ProcessingLogEntry, correction:CuratedPhoto? = nil) {
        let existing = items.firstIndex { item in item.key.flatMap { entries[$0] }.map { $0.root == entry.root && $0.record.id == entry.record.id } == true }
        let key = existing.flatMap { items[$0].key } ?? ("gather-result://" + UUID().uuidString)
        entries[key] = entry
        let record = entry.record, finding = record.finding
        let choice = CurationEngine.initialPhoto(record,mode:entry.mode).choice
        let result:String, reason:String, color:NSColor
        if let correction {
            result = correction.choice.selected ? "已纠正" : "已不选"; reason = (correction.choice.selected ? correction.choice.category.title : "不选") + " · " + correction.reason; color = Memphis.mint
        }
        else if let error = record.error { result = "处理失败"; reason = error; color = Memphis.pink.withAlphaComponent(0.4) }
        else if entry.mode == .groups && finding?.detail.contains("不足两张") == true {
            result = "快速跳过"; reason = "可检测人脸不足2张"; color = Memphis.paper
        } else if entry.mode == .groups && finding?.scene.groupCandidate == false {
            result = "非合影"; reason = "未满足本次亲友正式合影条件"; color = Memphis.paper
        } else if choice.selected {
            result = entry.mode == .groups ? "自动入选" : "已归类"
            reason = entry.mode == .groups ? "人脸与眼睛检查通过" : choice.category.title
            color = Memphis.mint.withAlphaComponent(0.65)
        } else {
            result = "未入选"; reason = finding?.anomalies.first ?? "未满足本次入选条件"; color = Memphis.yellow.withAlphaComponent(0.6)
        }
        let item = ActivityItem(text:correction == nil ? text : "\(URL(fileURLWithPath:record.preview).lastPathComponent)：\(result) · \(reason)",key:key,file:URL(fileURLWithPath:record.preview).lastPathComponent,result:result,reason:reason,color:color)
        if let existing { items[existing] = item; if !batching { reloadData(forRowIndexes:IndexSet(integer:existing),columnIndexes:IndexSet(integersIn:0..<numberOfColumns)) } }
        else { insert(item) }
    }
    func numberOfRows(in tableView:NSTableView)->Int { items.count }
    func tableView(_ tableView:NSTableView, shouldSelectRow row:Int)->Bool { items.indices.contains(row) && items[row].key != nil }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? { ActivityRow() }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard items.indices.contains(row) else { return nil }; let item = items[row]
        switch tableColumn?.identifier.rawValue {
        case "result":
            guard !item.result.isEmpty else { return NSView() }
            let badge = ActivityBadge(); badge.title = item.result; badge.color = item.color; return badge
        case "open":
            return item.key == nil ? NSView() : symbol("chevron.right",size:10,color:Memphis.muted)
        default:
            let isFile = tableColumn?.identifier.rawValue == "file"
            let field = label(isFile ? item.file : item.reason,isFile ? 11 : 11,isFile && item.key != nil ? .semibold : .regular,isFile && item.key != nil ? Memphis.ink : Memphis.muted)
            field.maximumNumberOfLines = 1; field.lineBreakMode = isFile ? .byTruncatingMiddle : .byTruncatingTail
            let cell = NSView(); cell.addSubview(field); field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:6),field.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),field.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            cell.toolTip = item.key == nil ? item.text : item.file + "\n" + item.text + "\n点击查看照片与完整判断"
            return cell
        }
    }
    @objc private func activateSelection() { if clickedRow >= 0 { activateRow(clickedRow) } }
    func activateRow(_ row:Int) {
        guard items.indices.contains(row),let key = items[row].key,let entry = entries[key] else { return }
        selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); openEntry?(entry)
    }
    override func keyDown(with event:NSEvent) {
        if [36,49,76].contains(event.keyCode) { activateRow(selectedRow) } else { super.keyDown(with:event) }
    }
    override func scrollToEndOfDocument(_ sender:Any?) { if !items.isEmpty { scrollRowToVisible(items.count-1) } }
    override func resetCursorRects() {
        super.resetCursorRects(); let range = rows(in:visibleRect)
        guard range.location != NSNotFound else { return }
        for row in range.location..<NSMaxRange(range) where items.indices.contains(row) && items[row].key != nil { addCursorRect(rect(ofRow:row),cursor:.pointingHand) }
    }
    override func menu(for event:NSEvent)->NSMenu? {
        let row = self.row(at:convert(event.locationInWindow,from:nil))
        guard items.indices.contains(row),let key = items[row].key,let entry = entries[key] else { return nil }
        let menu = NSMenu()
        for (title,action) in [("查看照片与判断概要",#selector(openResult(_:))),("在访达中显示",#selector(revealResult(_:))),("复制原片路径",#selector(copyResultPath(_:))),("添加/编辑备注…",#selector(noteResult(_:))),("纠正本张…",#selector(correctResult(_:)))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; item.representedObject = entry; menu.addItem(item)
        }; return menu
    }
    @objc private func noteResult(_ item:NSMenuItem) { if let e = item.representedObject as? ProcessingLogEntry { noteEntry?(e) } }
    @objc private func correctResult(_ item:NSMenuItem) { if let e = item.representedObject as? ProcessingLogEntry { correctEntry?(e) } }
    @objc private func openResult(_ item:NSMenuItem) { if let e = item.representedObject as? ProcessingLogEntry { openEntry?(e) } }
    @objc private func revealResult(_ item:NSMenuItem) { if let e = item.representedObject as? ProcessingLogEntry { NSWorkspace.shared.activateFileViewerSelecting(e.record.sources.map { URL(fileURLWithPath:$0) }) } }
    @objc private func copyResultPath(_ item:NSMenuItem) { if let e = item.representedObject as? ProcessingLogEntry { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.record.sources.joined(separator:"\n"),forType:.string) } }
    @objc func copy(_ sender:Any?) {
        let text = selectedRowIndexes.isEmpty ? string : selectedRowIndexes.map { items[$0].text }.joined(separator:"\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)
    }
}
