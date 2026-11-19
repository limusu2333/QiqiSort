import AppKit

// Notes have a separate lock so an active model writer can never overwrite an edit.
enum TaskPhotoNotes {
    struct Saved:Codable { let taskID:String; var notes:[String:String] }
    static func path(_ root:URL)->URL { CurationFiles.directory(root).appendingPathComponent("photo-note-overrides.json") }
    static func identity(_ task:TaskRecord)->String { task.taskID ?? sha256(Data((task.mode.rawValue + task.inputs.sorted().joined(separator:"\n")).utf8)) }
    static func canonical(_ path:String)->String { URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath().path }
    static func overrides(_ root:URL,task:TaskRecord)->[String:String] {
        guard let saved = try? CurationFiles.read(Saved.self,path(root)),saved.taskID == identity(task) else { return [:] }
        let allowed = Set((task.inventory?.flatMap(\.sources) ?? []).map(canonical))
        return saved.notes.filter { allowed.contains($0.key) }
    }
    static func merged(_ root:URL,task:TaskRecord)->[String:String] {
        (task.photoNotes ?? [:]).merging(overrides(root,task:task),uniquingKeysWith: { _,new in new })
    }
    static func text(_ entry:ProcessingLogEntry)->String {
        guard let task = try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(entry.root).appendingPathComponent("task.json")) else { return "" }
        guard entry.taskID == nil || entry.taskID == identity(task) else { return "" }
        let notes = merged(entry.root,task:task)
        return entry.record.sources.compactMap { notes[canonical($0)] ?? notes[$0] }.first ?? ""
    }
    static func save(_ text:String,entry:ProcessingLogEntry,expectedTaskID:String? = nil) throws {
        guard text.count <= 2000 else { throw GatherError.message("备注最多2000字，请精简后保存") }
        let dir = CurationFiles.directory(entry.root)
        let lock = try GatherFileLock(dir.appendingPathComponent(".photo-notes.lock")); defer { withExtendedLifetime(lock) {} }
        let task = try CurationFiles.read(TaskRecord.self,dir.appendingPathComponent("task.json"))
        guard (expectedTaskID ?? entry.taskID) == nil || (expectedTaskID ?? entry.taskID) == identity(task) else { throw GatherError.message("任务已变更，请从当前任务重新打开照片") }
        guard task.inventory?.contains(where: { $0.id == entry.record.id && Set($0.sources.map(canonical)) == Set(entry.record.sources.map(canonical)) }) == true else { throw GatherError.message("照片不属于这个任务，备注未保存") }
        let old = try? CurationFiles.read(Saved.self,path(entry.root))
        guard old == nil || old?.taskID == identity(task) else { throw GatherError.message("原备注属于另一场任务，未覆盖") }
        var saved = old ?? Saved(taskID:identity(task),notes:[:])
        for source in entry.record.sources { saved.notes[canonical(source)] = text.trimmingCharacters(in:.whitespacesAndNewlines) }
        try CurationFiles.write(saved,path(entry.root))
    }
}

struct TaskNoteSaveResult { let message:String; var waitingForUser = false }

final class TaskPhotoNoteWindow:NSWindowController,NSTextViewDelegate {
    let entry:ProcessingLogEntry
    let taskIdentity:String
    let text = NSTextView(), notice = label("",12,.medium)
    let save = MemphisButton(title:"保存并复核本张",target:nil,action:nil)
    var onSave:((String)throws->TaskNoteSaveResult)?
    init(entry:ProcessingLogEntry) {
        self.entry = entry
        taskIdentity = entry.taskID ?? (try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(entry.root).appendingPathComponent("task.json"))).map(TaskPhotoNotes.identity) ?? ""
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:370),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window); window.title = "本图备注 · " + URL(fileURLWithPath:entry.record.preview).lastPathComponent
        window.minSize = NSSize(width:560,height:350); window.isReleasedWhenClosed = false; window.backgroundColor = Memphis.paper
        let background = WorkspaceBackground(); window.contentView!.addSubview(background); pin(background,to:window.contentView!)
        let info = label("备注仅辅助理解这张照片。处理中保存会先保存进度，复核后继续；明确改分类或不选，请用“纠正本张”。",12,.regular,mutedInk)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = text
        text.isRichText = false; text.font = .systemFont(ofSize:14); text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width:10,height:10)
        text.string = TaskPhotoNotes.text(entry); text.delegate = self
        notice.stringValue = "备注随本场任务保存，不自动成为其他照片的规则。"
        styleButton(save,primary:true,symbol:"arrow.triangle.2.circlepath"); save.target = self; save.action = #selector(saveNote)
        let clear = MemphisButton(title:"清除并复核",target:self,action:#selector(clearNote)); styleButton(clear,symbol:"eraser")
        let body = column([info,scroll,notice,row([clear,spacer(),save],spacing:12)],spacing:12)
        fullWidth(body.arrangedSubviews,in:body); scroll.setContentHuggingPriority(.init(1),for:.vertical)
        window.contentView!.addSubview(body); pin(body,to:window.contentView!,inset:20); window.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    func textDidChange(_ notification:Notification) { notice.stringValue = "备注尚未保存"; notice.textColor = Memphis.blue; save.isEnabled = true }
    @objc func saveNote() {
        do {
            guard let onSave else { return }
            let message = try onSave(text.string)
            notice.stringValue = message.message; notice.textColor = NSColor(hex:0x187A63); save.isEnabled = message.waitingForUser
            save.title = message.waitingForUser ? "复核本张" : "保存并复核本张"; save.invalidateIntrinsicContentSize()
        } catch { notice.stringValue = error.localizedDescription; notice.textColor = .systemRed; save.isEnabled = true }
    }
    @objc private func clearNote() { text.string = ""; saveNote() }
}
