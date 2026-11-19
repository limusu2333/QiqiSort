import AppKit

struct ProcessingLogEntry {
    let record: ResultRecord
    let root: URL
    let mode: TaskMode
    var taskID: String? = nil
}
enum ProcessingSummary {
    static func text(_ entry: ProcessingLogEntry) -> String {
        let r = entry.record
        var lines = ["当时的自动判断", "文件：" + URL(fileURLWithPath: r.preview).lastPathComponent,
                     "原片路径：\n" + r.sources.joined(separator: "\n")]
        if let task = try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(entry.root).appendingPathComponent("task.json")),
           let examples = try? LearningStore.shared.snapshot().examples,
           let correction = PhotoCorrections.saved(taskID:TaskPhotoNotes.identity(task),records:[r],examples:examples)[r.id]?.photo {
            lines.insert("用户已纠正：" + (correction.choice.selected ? correction.choice.category.title : "不选") + "\n" + correction.reason,at:0)
        }
        if let error = r.error { lines += ["处理异常：" + error] }
        guard let f = r.finding else { return (lines + ["识别未完成，没有可用的判断概要。可定位原片检查读取情况。"]).joined(separator: "\n\n") }
        let choice = CurationEngine.initialPhoto(r, mode: entry.mode)
        lines += ["自动结果：" + (choice.choice.selected ? "入选 · " + f.category : "本次未入选")]
        if entry.mode == .groups && f.detail.contains("不足两张") {
            lines += ["1. 人脸初筛：" + f.detail, "2. 后续判断：已提前跳过，未继续合影判别及眼睛检查。"]
        } else {
            lines += ["1. 初步判断与已保存的复核依据：\n" + f.detail,
                      "2. 最终合影结论：" + (f.scene.groupCandidate ? "属于合影候选" : "未判为合影候选")]
            if f.faces.isEmpty { lines += ["3. 人脸／眼睛：" + f.eyes] }
            else {
                let details = f.faces.map { face in
                    "\(face.participantID)号：\(face.passes ? "通过" : "不合格") · \(face.reason)"
                }.joined(separator: "\n")
                lines += ["3. 逐人检查（照片上显示相同编号）：\n" + details]
                if f.faces.count < f.scene.participants.count {
                    lines += [entry.mode == .groups ? "发现不合格后已提前结束余下检查；没有检查到的人不能视为通过。" : "部分人脸检查未完成，请核对。"]
                }
            }
        }
        if !f.scene.groupCandidate && f.detail.contains("合影判别器确认") {
            lines += ["初步合影判断在后续复核或经验应用后改变了。若下方没有保存具体原因，说明这份旧记录未保留该步骤，不能从最终结果倒推模型解释。"]
        }
        if let learning = f.learning {
            lines += ["4. 历史经验：检索\(learning.retrievedIDs.count)条，采用\(learning.appliedIDs.count)条\n" + learning.reason]
        }
        if let task = try? CurationFiles.read(TaskRecord.self, CurationFiles.directory(entry.root).appendingPathComponent("task.json")) {
            let currentNotes = TaskPhotoNotes.merged(entry.root,task:task)
            let notes = Array(Set(r.sources.compactMap { currentNotes[TaskPhotoNotes.canonical($0)] ?? currentNotes[$0] }.filter { !$0.isEmpty })).sorted()
            if !notes.isEmpty { lines += ["本图备注：\n" + notes.joined(separator: "\n")] }
        }
        lines += ["这里展示当时保存的判断依据与检查结果。之后的手动调整以选片工作台为准。"]
        var text = lines.joined(separator: "\n\n")
        for kind in ["couple", "party", "event", "group"] { text = text.replacingOccurrences(of: "用途核对（" + kind + "）", with: "用途核对（" + GroupScreening.kindTitle(kind) + "）") }
        return text
    }
}

final class ResultPhotoView: NoteActionsImageView {
    var finding: Finding?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image, let finding else { return }
        let factor = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        for person in finding.scene.participants {
            guard person.box.count == 4 else { continue }
            let check = finding.faces.first { $0.participantID == person.id }
            let color: NSColor = check == nil ? .systemYellow : (check!.passes ? .systemGreen : .systemRed)
            let box = NSRect(x: origin.x + person.box[0] * size.width, y: origin.y + (1 - person.box[1] - person.box[3]) * size.height,
                             width: person.box[2] * size.width, height: person.box[3] * size.height)
            color.setStroke(); let path = NSBezierPath(rect: box); path.lineWidth = 2; path.stroke()
            let badge = NSRect(x: box.minX, y: box.maxY, width: 24, height: 20); color.setFill(); badge.fill()
            (String(person.id) as NSString).draw(in: badge, withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black])
        }
    }
}
final class ProcessingDetailWindow: NSWindowController {
    let image = ResultPhotoView()
    let details = NSTextView()
    let stage: PhotoStage
    var entry: ProcessingLogEntry
    var onNote: ((ProcessingLogEntry)->Void)?
    var onCorrect: ((ProcessingLogEntry)->Void)?
    let noteButton = MemphisButton(title:"本图备注",target:nil,action:nil)
    let correctButton = MemphisButton(title:"纠正本张",target:nil,action:nil)
    let noteState = label("",11,.medium,mutedInk)
    let loading = label("正在加载预览…",13,.medium,.white)
    var headerButtons = [NSButton]()
    init(entry: ProcessingLogEntry) {
        self.entry = entry; stage = PhotoStage(imageView: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "照片与判断概要 · " + URL(fileURLWithPath: entry.record.preview).lastPathComponent
        window.minSize = NSSize(width: 850, height: 600); window.isReleasedWhenClosed = false; window.backgroundColor = Memphis.paper
        image.imageScaling = .scaleProportionallyUpOrDown; image.finding = entry.record.finding
        stage.addSubview(loading); loading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([loading.centerXAnchor.constraint(equalTo:stage.centerXAnchor),loading.centerYAnchor.constraint(equalTo:stage.centerYAnchor)])
        let reveal = MemphisButton(title: "在访达中显示", target: self, action: #selector(revealOriginal))
        let plus = MemphisButton(title: "放大 +", target: stage, action: #selector(PhotoStage.enlarge))
        let minus = MemphisButton(title: "缩小 −", target: stage, action: #selector(PhotoStage.reduce))
        noteButton.target = self; noteButton.action = #selector(editNote)
        correctButton.target = self; correctButton.action = #selector(correctPhoto)
        for button in [reveal, plus, minus, noteButton, correctButton] { styleButton(button) }
        noteButton.symbolName = "note.text"; correctButton.symbolName = "slider.horizontal.3"
        image.noteMenuContext = { [weak self] in
            guard let self else { return nil }; let entry = self.entry
            return PhotoNoteMenuContext(files:entry.record.sources.map { URL(fileURLWithPath:$0) },note: { [weak self] in self?.onNote?(entry) })
        }
        headerButtons = [reveal, noteButton, correctButton, plus, minus]
        let background = WorkspaceBackground(); window.contentView!.addSubview(background); pin(background, to: window.contentView!)
        let legend = label("绿：通过　红：不合格　黄：未检查", 11, .regular, mutedInk)
        let controls = row([reveal, noteButton, correctButton, spacer(), minus, plus], spacing: 12)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = details
        details.isEditable = false; details.isSelectable = true; details.isRichText = false; details.font = .systemFont(ofSize: 13)
        details.isVerticallyResizable = true; details.autoresizingMask = [.width]; details.textContainer?.widthTracksTextView = true
        details.textContainerInset = NSSize(width: 12, height: 12); details.string = ProcessingSummary.text(entry)
        let body = row([stage, scroll], spacing: 14); body.alignment = .top
        stage.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.52).isActive = true
        stage.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true; scroll.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        body.setContentHuggingPriority(.init(1), for: .vertical)
        let context = row([legend,spacer(),noteState],spacing:10)
        let stack = column([controls,context,body], spacing: 12); fullWidth([controls,context,body], in: stack)
        window.contentView!.addSubview(stack); pin(stack, to: window.contentView!, inset: 16); window.center()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var bitmap: CGImage?
            for source in [entry.record.preview] + entry.record.sources {
                if let decoded = ReviewPreviewLoader.decode(URL(fileURLWithPath:source),pixels:2400) { bitmap = decoded; break }
            }
            let decoded = bitmap
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading.isHidden = true
                if let decoded { self.image.image = NSImage(cgImage: decoded, size: .zero); self.image.needsDisplay = true }
                else { self.details.string = "原片当前无法读取。判断记录仍保留，可重新连接原片后查看。\n\n" + self.details.string }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func editNote() { onNote?(entry) }
    @objc private func correctPhoto() { onCorrect?(entry) }
    func updateEntry(_ next:ProcessingLogEntry) {
        entry = next; details.string = ProcessingSummary.text(next); image.finding = next.record.finding; image.needsDisplay = true
        noteState.stringValue = next.record.error == nil ? "本张判断已更新" : "本张复核失败，可查看原因"
    }
    @objc private func revealOriginal() { NSWorkspace.shared.activateFileViewerSelecting(entry.record.sources.map { URL(fileURLWithPath: $0) }) }
}

extension App {
    func appendRecord(_ text: String, record: ResultRecord, root: URL, mode: TaskMode) {
        let follows = log.visibleRect.height <= 0 || log.visibleRect.maxY >= log.bounds.maxY - 24
        if activeTaskIdentity == nil || activeTaskIdentityRoot != root { activeTaskIdentityRoot = root; activeTaskIdentity = (try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(root).appendingPathComponent("task.json"))).map(TaskPhotoNotes.identity) }
        log.appendRecord(text, entry: ProcessingLogEntry(record: record, root: root, mode: mode, taskID:activeTaskIdentity),correction:correction(for:record))
        if follows { log.scrollToEndOfDocument(nil) }
        if processingDetail?.entry.root == root && processingDetail?.entry.record.id == record.id || noteEditor?.entry.root == root && noteEditor?.entry.record.id == record.id {
            let entry = ProcessingLogEntry(record:record,root:root,mode:mode,taskID:activeTaskIdentity)
            let task = try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(root).appendingPathComponent("task.json"))
            let current = task.map { TaskPhotoNotes.merged(root,task:$0) } ?? [:]
            let applied = ImportNotes.context(record.sources.map { URL(fileURLWithPath:$0) },notes:runPhotoNotes) == ImportNotes.context(record.sources.map { URL(fileURLWithPath:$0) },notes:current)
            if processingDetail?.entry.root == root && processingDetail?.entry.record.id == record.id {
                processingDetail?.updateEntry(entry)
                if !applied { processingDetail?.noteState.stringValue = "新备注已保存，等待复核" }
            }
            if noteEditor?.entry.root == root && noteEditor?.entry.record.id == record.id {
                noteEditor?.notice.stringValue = !applied ? "备注已保存，等待复核。" : record.error == nil ? "本张已按当前备注完成复核。" : "本张复核失败，请查看判断中的原因。"
            }
        }
    }
    func showProcessingDetail(_ entry: ProcessingLogEntry) {
        processingDetail?.close(); processingDetail = ProcessingDetailWindow(entry: entry)
        processingDetail?.onNote = { [weak self] in self?.editTaskNote($0) }
        processingDetail?.onCorrect = { [weak self] in self?.correctTaskPhoto($0) }
        processingDetail?.showWindow(nil)
    }
    func restoreProcessingLog(_ root: URL) {
        let directory = CurationFiles.directory(root)
        guard let records = try? CurationFiles.read([ResultRecord].self, directory.appendingPathComponent("results.json")),
              let task = try? CurationFiles.read(TaskRecord.self, directory.appendingPathComponent("task.json")) else { return }
        loadCorrectionHistory(root,records:records)
        log.performBatch {
        log.string = "模式：\(task.mode == .groups ? "只挑合影" : "整理照片")\n结果位置：\(root.path)\n点击任意照片记录查看完整判断。\n"; log.entries.removeAll()
        for record in records {
            let name = URL(fileURLWithPath: record.preview).lastPathComponent
            let result = record.error != nil ? "处理异常" : (CurationEngine.initialPhoto(record, mode: task.mode).choice.selected ? "自动入选" : "本次未入选")
            log.appendRecord(name + "：" + result, entry: ProcessingLogEntry(record: record, root: root, mode: task.mode,taskID:TaskPhotoNotes.identity(task)),correction:correction(for:record))
        }
        }
        log.scrollToEndOfDocument(nil)
    }
}
