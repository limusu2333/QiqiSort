import AppKit

enum MetricFilter: Int, CaseIterable {
    case processed, kept, pending, failed
    var title: String { ["已处理", "合影入选", "待决定", "处理失败"][rawValue] }
    var empty: String { ["暂时没有已完成的照片，处理后会自动显示", "当前没有入选合影", "当前没有待决定的照片", "当前没有处理失败的照片"][rawValue] }
}
final class MetricCard: NSControl {
    private let surface: NSView
    init(surface: NSView, title: String) {
        self.surface = surface; super.init(frame: .zero)
        addSubview(surface); pin(surface, to: self); heightAnchor.constraint(equalToConstant: 64).isActive = true
        toolTip = "点击查看“\(title)”照片，双击照片可查看判断详情"
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        if let paper = surface as? PaperSurface {
            paper.highlighted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { paper.highlighted = false }
        }
        _ = sendAction(action, to: target)
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); performClick(self) }
    override func keyDown(with event: NSEvent) {
        if [36,49,76].contains(event.keyCode) { performClick(self) } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { performClick(self); return true }
}
struct MetricSnapshot {
    let root: URL
    let task: TaskRecord
    let records: [ResultRecord]
    let keptIDs: Set<String>
    let pendingIDs: Set<String>
    let pendingGroupCount: Int
    let notes: [String:String]
    static func load(_ root: URL) throws -> MetricSnapshot {
        let dir = CurationFiles.directory(root)
        let task = try CurationFiles.read(TaskRecord.self, dir.appendingPathComponent("task.json"))
        let records = try CurationFiles.read([ResultRecord].self, dir.appendingPathComponent("results.json"))
        let saved = try? CurationFiles.read(CurationPlan.self, dir.appendingPathComponent("curation.json"))
        let plan = saved.flatMap { $0.basis == (try? CurationFiles.basis(task, records: records)) ? $0 : nil }
        var choices = plan?.photos ?? records.map { CurationEngine.initialPhoto($0, mode: task.mode) }
        // A running task's final plan can lag behind results. Explicit saved choices
        // still apply to the same photo bytes while the remainder is being processed.
        let examples = (try? LearningStore.shared.snapshot().examples) ?? []
        let corrections = PhotoCorrections.saved(taskID:TaskPhotoNotes.identity(task),records:records,examples:examples)
        for index in choices.indices { if let correction = corrections[choices[index].recordID] { choices[index] = correction.photo } }
        let pending = (plan?.exceptions ?? []).filter { $0.status == "pending" && !$0.recordIDs.allSatisfy { corrections[$0] != nil } }
        return MetricSnapshot(root: root, task: task, records: records,
            keptIDs: Set(choices.filter { $0.choice.selected && $0.choice.category == .group }.map(\.recordID)),
            pendingIDs: Set(pending.flatMap(\.recordIDs)).subtracting(corrections.keys),
            pendingGroupCount: pending.count,notes:TaskPhotoNotes.merged(root,task:task))
    }
    func filtered(_ filter: MetricFilter) -> [ResultRecord] {
        records.filter { record in
            switch filter {
            case .processed: return true
            case .kept: return keptIDs.contains(record.id)
            case .pending: return pendingIDs.contains(record.id)
            case .failed: return record.error != nil
            }
        }
    }
}
final class MetricBrowser: NSObject, NSWindowDelegate {
    let gallery = ImportGallery()
    var filter = MetricFilter.processed
    var root: URL?
    private(set) var snapshot: MetricSnapshot?
    private(set) var visibleRecords = [ResultRecord]()
    private var timer: Timer?
    private var loading = false
    private var generation = UUID()
    private var loadVersion = 0
    var didLoad: ((MetricSnapshot) -> Void)?
    var openRecord: ((ProcessingLogEntry) -> Void)?
    var noteEntry: ((ProcessingLogEntry) -> Void)?
    override init() {
        super.init(); gallery.window?.delegate = self
        gallery.strip.noteFor = { [weak self] files in
            guard let notes = self?.snapshot?.notes else { return nil }
            return files.compactMap { notes[$0.path] ?? notes[TaskPhotoNotes.canonical($0.path)] }.first { !$0.isEmpty }
        }
        gallery.strip.onNote = { [weak self] files in
            guard let self,let snapshot = self.snapshot,let file = files.first,let record = snapshot.records.first(where: { $0.preview == file.path }) else { return }
            self.noteEntry?(ProcessingLogEntry(record:record,root:snapshot.root,mode:snapshot.task.mode,taskID:TaskPhotoNotes.identity(snapshot.task)))
        }
        gallery.strip.onOpen = { [weak self] files in
            guard let self, let file = files.first, let snapshot = self.snapshot,
                  let record = snapshot.records.first(where: { $0.preview == file.path }) else { return }
            self.openRecord?(ProcessingLogEntry(record: record, root: snapshot.root, mode: snapshot.task.mode,taskID:TaskPhotoNotes.identity(snapshot.task)))
        }
    }
    func show(root: URL?, filter: MetricFilter) {
        let changed = self.root != root || self.filter != filter
        if self.root != root { snapshot = nil; generation = UUID() }
        self.root = root; self.filter = filter
        if changed { gallery.show([]) }
        render()
        gallery.window?.makeKeyAndOrderFront(nil)
        refresh()
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        guard !loading, let root, gallery.window?.isVisible == true else { return }
        loading = true; let token = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = try? MetricSnapshot.load(root)
            DispatchQueue.main.async {
                guard let self else { return }; self.loading = false
                guard self.generation == token else { self.refresh(); return }
                self.snapshot = result; self.loadVersion += 1; self.render()
                if let result { self.didLoad?(result) }
            }
        }
    }
    private func render() {
        guard let snapshot else {
            visibleRecords = []; gallery.show([])
            gallery.emptyLabel.stringValue = root == nil ? "还没有处理结果，开始任务后可在这里查看" : "正在准备或读取结果，请稍候…"
            gallery.window?.title = filter.title + " · 尚无结果"; return
        }
        visibleRecords = snapshot.filtered(filter)
        let photos = visibleRecords.map { record in
            [URL(fileURLWithPath: record.preview)] + record.sources.filter { $0 != record.preview }.map { URL(fileURLWithPath: $0) }
        }
        gallery.update(photos)
        gallery.emptyLabel.stringValue = filter.empty
        let count = filter == .pending ? "\(snapshot.pendingGroupCount)项 · \(visibleRecords.count)组底片" : "\(visibleRecords.count)组"
        gallery.window?.title = "\(filter.title) · \(count) · 已完成\(snapshot.records.count)/\(snapshot.task.total)组 · \(snapshot.root.lastPathComponent) · 双击查看照片与判断"
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}
extension App {
    @objc func openMetric(_ sender: NSControl) {
        guard let filter = MetricFilter(rawValue: sender.tag) else { return }
        if metricBrowser == nil {
            let browser = MetricBrowser(); metricBrowser = browser
            browser.noteEntry = { [weak self] entry in self?.editTaskNote(entry) }
            browser.openRecord = { [weak self] entry in self?.showProcessingDetail(entry) }
            browser.didLoad = { [weak self] snapshot in
                guard let self, self.output == snapshot.root, !self.busy else { return }
                self.originalCount.stringValue = String(snapshot.records.count)
                self.groupCount.stringValue = String(snapshot.keptIDs.count)
                self.exceptionCount.stringValue = String(snapshot.pendingGroupCount)
                self.pendingCount.stringValue = String(snapshot.records.filter { $0.error != nil }.count)
            }
        }
        metricBrowser?.show(root: output, filter: filter)
    }
}
